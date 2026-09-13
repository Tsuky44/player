package handlers

import (
	"encoding/json"
	"github.com/julienschmidt/httprouter"
	"net/http/httptest"
	"os"
	"path/filepath"
	"project-player/server/database"
	"project-player/server/playbackauth"
	"project-player/server/streamcache"
	"strings"
	"testing"
)

func TestTicketIssuanceAndProtectedRange(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	old := PlaybackTickets
	PlaybackTickets = playbackauth.NewStore()
	defer func() { PlaybackTickets = old }()
	file := filepath.Join(t.TempDir(), "clip.mp4")
	if err := os.WriteFile(file, []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := database.DB.Exec("UPDATE medias SET file_path = ? WHERE id = 3", file); err != nil {
		t.Fatal(err)
	}
	if _, err := database.DB.Exec("INSERT INTO sessions (token, user_id) VALUES ('login-token', 1)"); err != nil {
		t.Fatal(err)
	}
	if err := InitStream(); err != nil {
		t.Fatal(err)
	}
	defer streamLookupStmt.Close()
	streamcache.Global().Invalidate(3)
	defer streamcache.Global().Invalidate(3)
	issue := RequireAuth(CreatePlaybackTicket)
	w := httptest.NewRecorder()
	issue(w, httptest.NewRequest("POST", "/api/playback/tickets", strings.NewReader(`{"media_id":3}`)), nil)
	if w.Code != 401 {
		t.Fatal("anonymous ticket issuance accepted")
	}
	r := httptest.NewRequest("POST", "/api/playback/tickets", strings.NewReader(`{"media_id":3}`))
	r.Header.Set("Authorization", "Bearer login-token")
	w = httptest.NewRecorder()
	issue(w, r, nil)
	if w.Code != 200 {
		t.Fatalf("issue: %d %s", w.Code, w.Body.String())
	}
	var result struct {
		Ticket string `json:"ticket"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Ticket) != 43 || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("invalid ticket response")
	}
	for _, c := range []struct {
		token  string
		status int
	}{{"", 401}, {result.Ticket, 206}} {
		w = httptest.NewRecorder()
		r = httptest.NewRequest("GET", "/stream?media_id=3&ticket="+c.token, nil)
		r.Header.Set("Range", "bytes=2-5")
		StreamMedia(w, r, nil)
		if w.Code != c.status {
			t.Fatalf("stream = %d, want %d", w.Code, c.status)
		}
		if c.status == 206 && (w.Body.String() != "2345" || w.Header().Get("Content-Range") != "bytes 2-5/10") {
			t.Fatal("Range changed under authorization")
		}
	}
	PlaybackTickets.Revoke(result.Ticket, 1)
	w = httptest.NewRecorder()
	StreamMedia(w, httptest.NewRequest("GET", "/stream?media_id=3&ticket="+result.Ticket, nil), nil)
	if w.Code != 401 {
		t.Fatal("revoked direct URL accepted")
	}
	// Both subtitle route shapes share the same authorization, including when
	// a native engine asks without an Authorization header.
	sub := filepath.Join(t.TempDir(), "fra.vtt")
	if err := os.WriteFile(sub, []byte("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nBonjour\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := database.DB.Exec("INSERT INTO subtitles (media_id, language, path) VALUES (3, 'fra', ?)", sub); err != nil {
		t.Fatal(err)
	}
	token, _, _ := PlaybackTickets.Issue(1, 3)
	other, _, _ := PlaybackTickets.Issue(1, 4)
	params := httprouter.Params{{Key: "id", Value: "3"}, {Key: "file", Value: "fra.vtt"}}
	for _, c := range []struct {
		token  string
		status int
	}{{"", 401}, {other, 401}, {token, 200}} {
		w = httptest.NewRecorder()
		GetMediaSubtitle(w, httptest.NewRequest("GET", "/api/v1/media/3/subtitles/fra.vtt?ticket="+c.token, nil), params)
		if w.Code != c.status {
			t.Fatalf("subtitle = %d, want %d", w.Code, c.status)
		}
		if c.status == 200 && (!strings.Contains(w.Body.String(), "Bonjour") || w.Header().Get("Cache-Control") != "private, no-store") {
			t.Fatal("protected subtitle changed")
		}
	}
}
