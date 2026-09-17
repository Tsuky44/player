package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

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

func TestEmbyNeedsPush(t *testing.T) {
	item := func(ud embyUserData) embyItem { return embyItem{UserData: &ud} }
	local := PortableProgress{Position: 120, UpdatedAt: "2022-01-01T10:00:00Z"}
	if !embyNeedsPush(local, embyItem{}) {
		t.Fatal("unknown on Emby must be pushed")
	}
	if embyNeedsPush(local, item(embyUserData{PlaybackPositionTicks: 125 * ticksPerSecond})) {
		t.Fatal("same position must not be pushed")
	}
	if embyNeedsPush(local, item(embyUserData{PlaybackPositionTicks: 900 * ticksPerSecond, LastPlayedDate: "2023-01-01T00:00:00Z"})) {
		t.Fatal("older local progress must not overwrite Emby")
	}
	finished := PortableProgress{Finished: true, UpdatedAt: "2022-01-01T10:00:00Z"}
	if embyNeedsPush(finished, item(embyUserData{Played: true})) {
		t.Fatal("already played on Emby")
	}
}
