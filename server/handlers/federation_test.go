package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

const testPeerSecret = "0123456789abcdef0123456789abcdef"

func changeSeq(t *testing.T, userID int) int {
	t.Helper()
	var seq int
	if err := database.DB.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM progress_changes WHERE user_id = ?`, userID).Scan(&seq); err != nil {
		t.Fatal(err)
	}
	return seq
}

func insertPeer(t *testing.T, url string, local, remote bool) int {
	t.Helper()
	res, err := database.DB.Exec(`INSERT INTO peer_servers (server_id, name, url, secret, local_approved, remote_approved)
		VALUES ('remote-server', 'Chez Paul', ?, ?, ?, ?)`, url, testPeerSecret, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func resetFederationState() {
	peerBackoffs = map[int]*peerBackoff{}
}

// Toute écriture de progression entre au journal, mais l'écho d'un serveur lié
// — la même entrée, à la même date — n'y entre pas : sans cela, deux serveurs
// se renverraient la même progression indéfiniment.
func TestProgressChanges_JournalStopsEchoes(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	if _, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show'`); err != nil {
		t.Fatal(err)
	}
	first := changeSeq(t, 1)
	if first == 0 {
		t.Fatal("existing history should be journaled")
	}
	entries, _, _, err := pendingChanges(1, 0)
	if err != nil || len(entries) != 1 {
		t.Fatalf("pending: %v %#v", err, entries)
	}
	// Le premier passage peut réécrire une date à l'ancien format ; l'écho
	// suivant, lui, ne change plus rien.
	if err := importPortableProgress(1, entries); err != nil {
		t.Fatal(err)
	}
	entries, _, _, _ = pendingChanges(1, 0)
	first = changeSeq(t, 1)
	if err := importPortableProgress(1, entries); err != nil {
		t.Fatal(err)
	}
	if got := changeSeq(t, 1); got != first {
		t.Fatalf("echo was journaled again: %d -> %d", first, got)
	}
	newer := entries[0]
	newer.Position = 900
	newer.UpdatedAt = "2030-01-01T00:00:00Z"
	if err := importPortableProgress(1, []PortableProgress{newer}); err != nil {
		t.Fatal(err)
	}
	if got := changeSeq(t, 1); got <= first {
		t.Fatalf("a real change must be journaled: %d -> %d", first, got)
	}
}

func claim(t *testing.T, body claimBody) *httptest.ResponseRecorder {
	t.Helper()
	payload, _ := json.Marshal(body)
	rec := httptest.NewRecorder()
	ClaimAccountLink(rec, httptest.NewRequest(http.MethodPost, "/api/federation/claim", strings.NewReader(string(payload))), nil)
	return rec
}

func linkCode(t *testing.T, userID int) string {
	t.Helper()
	rec := httptest.NewRecorder()
	CreateLinkCode(rec, httptest.NewRequest(http.MethodPost, "/api/links/code", nil), nil, userID)
	var out struct {
		Code string `json:"code"`
	}
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &out) != nil || out.Code == "" {
		t.Fatalf("link code: %d %s", rec.Code, rec.Body)
	}
	return out.Code
}

func TestClaimAccountLink_CodeIsSingleUseAndSecretIsPinned(t *testing.T) {
	setupAuthDB(t)
	bob := createTestUser(t, "bob", false, models.Permissions{})
	body := claimBody{
		Code: linkCode(t, bob), ServerID: "remote-server", Name: "Chez Paul", URL: "http://paul.local:8080/",
		Secret: testPeerSecret, UserID: 7, Username: "alice",
	}
	rec := claim(t, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("claim: %d %s", rec.Code, rec.Body)
	}
	var resp claimResponse
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.UserID != bob || resp.Username != "bob" || resp.Approved {
		t.Fatalf("response: %#v", resp)
	}
	links, _ := listAccountLinks(bob)
	if len(links) != 1 || links[0].Status != "pending" || links[0].RemoteUsername != "alice" ||
		links[0].URL != "http://paul.local:8080" {
		t.Fatalf("links: %#v", links)
	}
	if rec := claim(t, body); rec.Code != http.StatusBadRequest {
		t.Fatalf("a code must not be reusable: %d", rec.Code)
	}
	body.Code = linkCode(t, bob)
	body.Secret = strings.Repeat("f", 32)
	if rec := claim(t, body); rec.Code != http.StatusConflict {
		t.Fatalf("another secret for a known server must be refused: %d", rec.Code)
	}
	body.Secret = testPeerSecret
	body.UserID = 8
	if rec := claim(t, body); rec.Code != http.StatusConflict {
		t.Fatalf("an account links to at most one account per server: %d", rec.Code)
	}
}

// Les administrateurs acceptent une fois par paire : un second compte qui lie
// les deux mêmes serveurs est actif aussitôt.
func TestClaimAccountLink_SecondAccountNeedsNoNewApproval(t *testing.T) {
	setupAuthDB(t)
	bob := createTestUser(t, "bob", false, models.Permissions{})
	carol := createTestUser(t, "carol", false, models.Permissions{})
	body := claimBody{
		Code: linkCode(t, bob), ServerID: "remote-server", Name: "Chez Paul", URL: "http://paul.local",
		Secret: testPeerSecret, UserID: 7, Username: "alice",
	}
	if rec := claim(t, body); rec.Code != http.StatusOK {
		t.Fatal(rec.Body)
	}
	database.DB.Exec(`UPDATE peer_servers SET local_approved = 1`)
	body.Code, body.UserID, body.Username, body.Approved = linkCode(t, carol), 9, "dave", true
	rec := claim(t, body)
	var resp claimResponse
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if rec.Code != http.StatusOK || !resp.Approved {
		t.Fatalf("claim: %d %s", rec.Code, rec.Body)
	}
	links, _ := listAccountLinks(carol)
	if len(links) != 1 || links[0].Status != "active" {
		t.Fatalf("links: %#v", links)
	}
}

func peerRequest(path, serverID, secret, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set(peerHeader, serverID)
	req.Header.Set("Authorization", "Bearer "+secret)
	return req
}

func TestPeerProgress_RequiresSecretApprovalAndLink(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show'`)
	peerID := insertPeer(t, "http://paul.local", false, false)
	body := `{"from_user_id":7,"to_user_id":1,"entries":[{"type":"episode","tmdb_id":42,"season_number":1,"episode_number":5,"current_position_seconds":1000,"is_finished":false,"updated_at":"2030-01-01T00:00:00Z"}]}`
	handler := RequirePeer(PeerProgress)
	send := func(secret string) int {
		rec := httptest.NewRecorder()
		handler(rec, peerRequest("/api/federation/progress", "remote-server", secret, body), nil)
		return rec.Code
	}
	if code := send(strings.Repeat("x", 32)); code != http.StatusUnauthorized {
		t.Fatalf("wrong secret: %d", code)
	}
	if code := send(testPeerSecret); code != http.StatusForbidden {
		t.Fatalf("not approved here: %d", code)
	}
	database.DB.Exec(`UPDATE peer_servers SET local_approved = 1`)
	if code := send(testPeerSecret); code != http.StatusNotFound {
		t.Fatalf("no account link: %d", code)
	}
	database.DB.Exec(`INSERT INTO account_links (user_id, peer_id, remote_user_id) VALUES (1, ?, 7)`, peerID)
	if code := send(testPeerSecret); code != http.StatusOK {
		t.Fatalf("linked: %d", code)
	}
	var position int
	var remoteApproved bool
	database.DB.QueryRow(`SELECT current_position_seconds FROM progressions WHERE user_id = 1`).Scan(&position)
	database.DB.QueryRow(`SELECT remote_approved FROM peer_servers`).Scan(&remoteApproved)
	if position != 1000 || !remoteApproved {
		t.Fatalf("position=%d remoteApproved=%v", position, remoteApproved)
	}
}

type fakePeer struct {
	mu       sync.Mutex
	server   *httptest.Server
	requests map[string][]json.RawMessage
	status   int
}

func newFakePeer(t *testing.T) *fakePeer {
	f := &fakePeer{requests: map[string][]json.RawMessage{}, status: http.StatusOK}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		var raw json.RawMessage
		json.NewDecoder(r.Body).Decode(&raw)
		f.requests[r.URL.Path] = append(f.requests[r.URL.Path], raw)
		switch r.URL.Path {
		case "/api/federation/info":
			w.Write([]byte(`{"server_id":"remote-server","name":"Chez Paul","federation":1}`))
		case "/api/federation/claim":
			w.Write([]byte(`{"server_id":"remote-server","name":"Chez Paul","user_id":7,"username":"alice","approved":true}`))
		default:
			if r.Header.Get("Authorization") != "Bearer "+testPeerSecret && r.URL.Path != "/api/federation/approval" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.WriteHeader(f.status)
			w.Write([]byte(`{}`))
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakePeer) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests[path])
}

func TestFederationPass_PushesOnlyNewChanges(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	resetFederationState()
	database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show'`)
	fake := newFakePeer(t)
	peerID := insertPeer(t, fake.server.URL, true, true)
	database.DB.Exec(`INSERT INTO account_links (user_id, peer_id, remote_user_id) VALUES (1, ?, 7)`, peerID)

	federationPass(context.Background())
	if fake.count("/api/federation/progress") != 1 {
		t.Fatalf("history should be pushed once: %v", fake.requests)
	}
	var sent peerProgressBody
	json.Unmarshal(fake.requests["/api/federation/progress"][0], &sent)
	if sent.FromUserID != 1 || sent.ToUserID != 7 || len(sent.Entries) != 1 || sent.Entries[0].Position != 254 {
		t.Fatalf("sent: %#v", sent)
	}
	federationPass(context.Background())
	if fake.count("/api/federation/progress") != 1 {
		t.Fatal("nothing new must not be pushed again")
	}
	database.DB.Exec(`UPDATE progressions SET current_position_seconds = 600, updated_at = '2031-01-01 00:00:00.000000000'`)
	federationPass(context.Background())
	if fake.count("/api/federation/progress") != 2 {
		t.Fatal("a change must be pushed")
	}

	fake.mu.Lock()
	fake.status = http.StatusNotFound
	fake.mu.Unlock()
	database.DB.Exec(`UPDATE progressions SET current_position_seconds = 700`)
	federationPass(context.Background())
	var links int
	database.DB.QueryRow(`SELECT COUNT(*) FROM account_links`).Scan(&links)
	if links != 0 {
		t.Fatal("a link the other server forgot must be dropped")
	}
}

func TestCreateAccountLink_ServerClaimsThenApprovalIsSent(t *testing.T) {
	setupAuthDB(t)
	resetFederationState()
	alice := createTestUser(t, "alice", false, models.Permissions{})
	fake := newFakePeer(t)
	body := `{"url":"` + fake.server.URL + `","self_url":"http://maison.local:8080","code":"abc"}`
	rec := httptest.NewRecorder()
	CreateAccountLink(rec, httptest.NewRequest(http.MethodPost, "/api/links", strings.NewReader(body)), nil, alice)
	if rec.Code != http.StatusOK {
		t.Fatalf("create link: %d %s", rec.Code, rec.Body)
	}
	var claimSent claimBody
	json.Unmarshal(fake.requests["/api/federation/claim"][0], &claimSent)
	if claimSent.Code != "abc" || claimSent.URL != "http://maison.local:8080" || claimSent.UserID != alice ||
		claimSent.Approved || len(claimSent.Secret) < 32 {
		t.Fatalf("claim sent: %#v", claimSent)
	}
	var link AccountLink
	json.Unmarshal(rec.Body.Bytes(), &link)
	if link.Status != "pending" || link.RemoteUsername != "alice" || link.ServerName != "Chez Paul" {
		t.Fatalf("link: %#v", link)
	}

	var peerID int
	database.DB.QueryRow(`SELECT id FROM peer_servers`).Scan(&peerID)
	rec = httptest.NewRecorder()
	ApprovePeerServer(rec, httptest.NewRequest(http.MethodPost, "/", nil), httprouter.Params{{Key: "id", Value: strconv.Itoa(peerID)}}, 0)
	var peer PeerServer
	json.Unmarshal(rec.Body.Bytes(), &peer)
	if rec.Code != http.StatusOK || !peer.Active {
		t.Fatalf("approve: %d %s", rec.Code, rec.Body)
	}
	federationPass(context.Background())
	if fake.count("/api/federation/approval") != 1 {
		t.Fatal("approval must be sent to the other server")
	}
	federationPass(context.Background())
	if fake.count("/api/federation/approval") != 1 {
		t.Fatal("approval must be sent once")
	}
}
