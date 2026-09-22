package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"project-player/server/database"
)

// fakeEmby joue un serveur Emby : un film en cours (TMDB 7) et une série
// (TMDB 42) dont l'épisode 1x5 n'a jamais été regardé.
type fakeEmby struct {
	mu       sync.Mutex
	userData map[string]embyUserData
	posts    map[string]embyUserData
}

func newFakeEmby(t *testing.T) (*fakeEmby, *httptest.Server) {
	f := &fakeEmby{
		userData: map[string]embyUserData{
			"m7": {PlaybackPositionTicks: 600 * ticksPerSecond, LastPlayedDate: "2021-03-04T05:06:07.0000000Z"},
		},
		posts: map[string]embyUserData{},
	}
	one, five := 1, 5
	items := map[string]embyItem{
		"m7":  {ID: "m7", Type: "Movie", RunTimeTicks: 5400 * ticksPerSecond, ProviderIds: map[string]string{"Tmdb": "7"}},
		"s42": {ID: "s42", Type: "Series", ProviderIds: map[string]string{"Tmdb": "42"}},
		"e5":  {ID: "e5", Type: "Episode", SeriesID: "s42", ParentIndexNumber: &one, IndexNumber: &five, RunTimeTicks: 2820 * ticksPerSecond},
	}
	withData := func(item embyItem) embyItem {
		ud := f.userData[item.ID]
		item.UserData = &ud
		return item
	}
	page := func(w http.ResponseWriter, list []embyItem) {
		json.NewEncoder(w).Encode(embyItemsPage{Items: list, TotalRecordCount: len(list)})
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Path == "/Users/AuthenticateByName" {
			var body map[string]string
			json.NewDecoder(r.Body).Decode(&body)
			if body["Pw"] != "secret" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"AccessToken": "tok", "User": map[string]string{"Id": "u1", "Name": body["Username"]}})
			return
		}
		if r.Header.Get("X-Emby-Token") != "tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		q := r.URL.Query()
		switch {
		case r.URL.Path == "/Shows/s42/Episodes":
			page(w, []embyItem{items["e5"]})
		case strings.HasSuffix(r.URL.Path, "/UserData") && r.Method == http.MethodPost:
			id := strings.Split(r.URL.Path, "/")[4]
			var ud embyUserData
			json.NewDecoder(r.Body).Decode(&ud)
			f.posts[id] = ud
			f.userData[id] = ud
		case r.URL.Path == "/Users/u1/Items" && q.Get("Ids") != "":
			var list []embyItem
			for _, id := range strings.Split(q.Get("Ids"), ",") {
				list = append(list, withData(items[id]))
			}
			page(w, list)
		case r.URL.Path == "/Users/u1/Items" && q.Get("IncludeItemTypes") == "Movie":
			page(w, []embyItem{items["m7"]})
		case r.URL.Path == "/Users/u1/Items" && q.Get("IncludeItemTypes") == "Series":
			page(w, []embyItem{items["s42"]})
		case r.URL.Path == "/Users/u1/Items" && q.Get("Filters") == "IsResumable":
			page(w, []embyItem{withData(items["m7"])})
		case r.URL.Path == "/Users/u1/Items" && q.Get("Filters") == "IsPlayed":
			page(w, nil)
		default:
			t.Errorf("unexpected Emby call %s %s", r.Method, r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	return f, server
}

func TestEmbySyncBothWays(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	if _, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show';
		INSERT INTO medias(id, type, title, tmdb_id, duration) VALUES (100, 'movie', 'Film', 7, 5400);`); err != nil {
		t.Fatal(err)
	}
	fake, server := newFakeEmby(t)
	defer server.Close()

	link := func(password string) int {
		body, _ := json.Marshal(embyLinkRequest{URL: server.URL, Username: "moi", Password: password})
		w := httptest.NewRecorder()
		LinkEmby(w, httptest.NewRequest(http.MethodPut, "/api/me/emby", bytes.NewReader(body)), nil, 1)
		return w.Code
	}
	if code := link("wrong"); code != http.StatusBadGateway {
		t.Fatalf("bad password accepted: %d", code)
	}
	if code := link("secret"); code != http.StatusOK {
		t.Fatalf("link: %d", code)
	}

	runSync := func() embySyncResult {
		t.Helper()
		w := httptest.NewRecorder()
		SyncEmbyNow(w, httptest.NewRequest(http.MethodPost, "/api/me/emby/sync", nil), nil, 1)
		if w.Code != http.StatusOK {
			t.Fatalf("sync: %d %s", w.Code, w.Body.String())
		}
		var result embySyncResult
		json.Unmarshal(w.Body.Bytes(), &result)
		return result
	}
	result := runSync()

	var position int
	if err := database.DB.QueryRow(`SELECT current_position_seconds FROM progressions WHERE user_id = 1 AND media_id = 100`).Scan(&position); err != nil || position != 600 {
		t.Fatalf("movie not pulled from Emby: %d %v", position, err)
	}
	fake.mu.Lock()
	episode, pushedEpisode := fake.posts["e5"]
	_, echoedMovie := fake.posts["m7"]
	fake.mu.Unlock()
	if !pushedEpisode || episode.PlaybackPositionTicks != 254*ticksPerSecond || episode.Played {
		t.Fatalf("episode not pushed to Emby: %#v", episode)
	}
	if echoedMovie {
		t.Fatal("movie imported from Emby was sent back")
	}
	if result.Pulled != 1 || result.Pushed != 1 {
		t.Fatalf("result: %#v", result)
	}
	if again := runSync(); again.Pulled != 0 || again.Pushed != 0 {
		t.Fatalf("second sync not idempotent: %#v", again)
	}

	status, err := loadEmbyStatus(1)
	if err != nil || !status.Linked || status.Username != "moi" || status.LastSyncAt == nil || status.LastError != "" {
		t.Fatalf("status: %#v %v", status, err)
	}
}

// Les scénarios qui départagent mal quand on compare des dates : Emby date
// une lecture de son *début*, jamais de sa dernière modification.
func TestDecideEmby(t *testing.T) {
	at := func(raw string) time.Time {
		v, _ := time.Parse(time.RFC3339, raw)
		return v
	}
	old, recent := at("2021-01-01T00:00:00Z"), at("2026-09-20T21:00:00Z")
	st := func(pos int, finished bool) progressState { return progressState{pos, finished} }
	base := func(pos int) *progressState { b := st(pos, false); return &b }

	cases := []struct {
		name            string
		local, emby     progressState
		localAt, embyAt time.Time
		base            *progressState
		want            embyVerdict
	}{
		{"même point, quelques secondes près", st(600, false), st(605, false), recent, old, nil, embyInSync},
		{"vu des deux côtés", st(5400, true), st(0, true), recent, old, nil, embyInSync},
		// Le bug remonté : une heure regardée sur Emby garde la date du début,
		// plus ancienne que la dernière écriture ici. Seul Emby a bougé.
		{"Emby a avancé, date de début ancienne", st(600, false), st(3600, false), recent, old, base(600), embyWins},
		// L'inverse : Onyx a avancé, Emby n'a pas bougé mais affiche une date
		// plus récente (horloge en avance, ou une lecture relancée puis arrêtée
		// au même endroit).
		{"Onyx a avancé, date Emby plus récente", st(1800, false), st(600, false), old, recent, base(600), onyxWins},
		{"un retour en arrière d'un seul côté compte aussi", st(120, false), st(600, false), old, recent, base(600), onyxWins},
		{"Emby vide n'efface pas Onyx", st(600, false), st(0, false), old, recent, base(600), onyxWins},
		{"Onyx vide n'efface pas Emby", st(0, false), st(600, false), recent, old, base(600), embyWins},
		{"les deux ont bougé : la date départage (Emby)", st(900, false), st(2000, false), old, recent, base(600), embyWins},
		{"les deux ont bougé : la date départage (Onyx)", st(900, false), st(2000, false), recent, old, base(600), onyxWins},
		{"aucun accord connu : la date départage", st(900, false), st(2000, false), recent, old, nil, onyxWins},
	}
	for _, c := range cases {
		if got := decideEmby(c.local, c.emby, c.localAt, c.embyAt, c.base); got != c.want {
			t.Errorf("%s : %v, attendu %v", c.name, got, c.want)
		}
	}
}

// setEmby change ce qu'Emby sait d'un élément, comme une lecture faite sur Emby.
func (f *fakeEmby) setEmby(id string, ud embyUserData) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.userData[id] = ud
	delete(f.posts, id)
}

func (f *fakeEmby) posted(id string) (embyUserData, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ud, ok := f.posts[id]
	return ud, ok
}

// linkedFixture lie le compte 1 au faux Emby et fait une première
// synchronisation : les accords existent, comme après quelques jours d'usage.
func linkedFixture(t *testing.T) (*fakeEmby, func() embySyncResult, func()) {
	t.Helper()
	cleanup := setupContinueWatchingTestDB(t)
	if _, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show';
		INSERT INTO medias(id, type, title, tmdb_id, duration) VALUES (100, 'movie', 'Film', 7, 5400);`); err != nil {
		t.Fatal(err)
	}
	fake, server := newFakeEmby(t)
	body, _ := json.Marshal(embyLinkRequest{URL: server.URL, Username: "moi", Password: "secret"})
	w := httptest.NewRecorder()
	LinkEmby(w, httptest.NewRequest(http.MethodPut, "/api/me/emby", bytes.NewReader(body)), nil, 1)
	if w.Code != http.StatusOK {
		t.Fatalf("link: %d", w.Code)
	}
	runSync := func() embySyncResult {
		t.Helper()
		w := httptest.NewRecorder()
		SyncEmbyNow(w, httptest.NewRequest(http.MethodPost, "/api/me/emby/sync", nil), nil, 1)
		if w.Code != http.StatusOK {
			t.Fatalf("sync: %d %s", w.Code, w.Body.String())
		}
		var result embySyncResult
		json.Unmarshal(w.Body.Bytes(), &result)
		return result
	}
	runSync()
	return fake, runSync, func() {
		server.Close()
		cleanup()
	}
}

func localPosition(t *testing.T, mediaID int) int {
	t.Helper()
	var position int
	if err := database.DB.QueryRow(`SELECT current_position_seconds FROM progressions
		WHERE user_id = 1 AND media_id = ?`, mediaID).Scan(&position); err != nil {
		t.Fatal(err)
	}
	return position
}

// Le bug remonté : une heure regardée sur Emby, Onyx n'a pas bougé. La date
// d'Emby est celle du début de la lecture, plus ancienne que la dernière
// écriture ici — l'ancienne règle donnait raison à Onyx et renvoyait sa
// position périmée sur Emby.
func TestEmbyProgressWinsDespiteOlderStartDate(t *testing.T) {
	fake, runSync, cleanup := linkedFixture(t)
	defer cleanup()

	fake.setEmby("m7", embyUserData{PlaybackPositionTicks: 3600 * ticksPerSecond, LastPlayedDate: "2021-03-04T05:06:07.0000000Z"})
	runSync()

	if got := localPosition(t, 100); got != 3600 {
		t.Fatalf("Onyx aurait dû reprendre la position d'Emby : %d", got)
	}
	if ud, sent := fake.posted("m7"); sent {
		t.Fatalf("Onyx a renvoyé une position périmée à Emby : %#v", ud)
	}
}

// L'inverse : Onyx avance, Emby n'a pas bougé mais porte une date plus récente.
func TestOnyxProgressWinsDespiteNewerEmbyDate(t *testing.T) {
	fake, runSync, cleanup := linkedFixture(t)
	defer cleanup()

	var episodeID int
	database.DB.QueryRow(`SELECT id FROM medias WHERE type = 'episode'`).Scan(&episodeID)
	// Emby a déjà l'épisode à 254 (envoyé à la première synchronisation), mais
	// avec une date à venir : une horloge en avance.
	fake.setEmby("e5", embyUserData{PlaybackPositionTicks: 254 * ticksPerSecond, LastPlayedDate: "2099-01-01T00:00:00.0000000Z"})
	if _, err := database.DB.Exec(`UPDATE progressions SET current_position_seconds = 1500, updated_at = ?
		WHERE user_id = 1 AND media_id = ?`, time.Now().UTC().Format(progressTimeLayout), episodeID); err != nil {
		t.Fatal(err)
	}
	runSync()

	ud, sent := fake.posted("e5")
	if !sent || ud.PlaybackPositionTicks != 1500*ticksPerSecond {
		t.Fatalf("la progression d'Onyx aurait dû partir vers Emby : %#v %v", ud, sent)
	}
	if got := localPosition(t, episodeID); got != 1500 {
		t.Fatalf("Onyx a été écrasé : %d", got)
	}
}

// Passer d'Emby à Onyx sans attendre la relecture des dix minutes : le point
// de reprise demandé par le lecteur doit déjà être celui d'Emby.
func TestResumePointAsksEmbyFirst(t *testing.T) {
	fake, _, cleanup := linkedFixture(t)
	defer cleanup()

	fake.setEmby("m7", embyUserData{PlaybackPositionTicks: 4200 * ticksPerSecond, LastPlayedDate: "2021-03-04T05:06:07.0000000Z"})

	w := httptest.NewRecorder()
	GetProgress(w, httptest.NewRequest(http.MethodGet, "/api/progress?media_id=100", nil), nil, 1)
	var body struct {
		Position int `json:"current_position_seconds"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err, w.Body.String())
	}
	if body.Position != 4200 {
		t.Fatalf("point de reprise périmé : %d", body.Position)
	}
}
