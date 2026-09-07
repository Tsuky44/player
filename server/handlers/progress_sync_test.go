package handlers

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"project-player/server/database"
	"testing"
)

func TestPortableProgressIdentityAndRecency(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	_, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show';
 INSERT INTO medias(id, type, title, tmdb_id) VALUES (100, 'movie', 'Different type', 42);
 INSERT INTO users(id, username, password_hash) VALUES (2, 'other', 'hash');`)
	if err != nil {
		t.Fatal(err)
	}
	send := func(entry PortableProgress, user int) int {
		t.Helper()
		body, _ := json.Marshal([]PortableProgress{entry})
		w := httptest.NewRecorder()
		ImportProgress(w, httptest.NewRequest("POST", "/api/progress/sync", bytes.NewReader(body)), nil, user)
		return w.Code
	}
	entry := PortableProgress{Type: "episode", TMDBID: 42, Season: 1, Episode: 5, Position: 800, UpdatedAt: "2020-01-02T00:00:00Z"}
	if code := send(entry, 1); code != 200 {
		t.Fatal(code)
	}
	var position int
	database.DB.QueryRow("SELECT current_position_seconds FROM progressions WHERE user_id = 1").Scan(&position)
	if position != 254 {
		t.Fatalf("old history rewound playback: %d", position)
	}
	if code := send(entry, 2); code != 200 {
		t.Fatal(code)
	}
	var mediaType string
	err = database.DB.QueryRow(`SELECT m.type, p.current_position_seconds FROM progressions p JOIN medias m ON m.id = p.media_id WHERE p.user_id = 2`).Scan(&mediaType, &position)
	if err != nil || mediaType != "episode" || position != 800 {
		t.Fatalf("identity: %s %d %v", mediaType, position, err)
	}
	entry.Position = 20
	entry.UpdatedAt = "2020-01-02T00:00:00.123456789Z"
	if code := send(entry, 2); code != 200 {
		t.Fatal(code)
	}
	w := httptest.NewRecorder()
	ExportProgress(w, httptest.NewRequest("GET", "/api/progress/sync", nil), nil, 2)
	var exported []PortableProgress
	if err := json.Unmarshal(w.Body.Bytes(), &exported); err != nil {
		t.Fatal(err, w.Body.String())
	}
	if len(exported) != 1 || exported[0] != entry {
		t.Fatalf("export: %#v", exported)
	}
	entry.Type = "movie"
	entry.Season = 0
	entry.Episode = 0
	entry.Finished = true
	if code := send(entry, 2); code != 200 {
		t.Fatal(code)
	}
	var finished bool
	if err := database.DB.QueryRow("SELECT is_finished FROM progressions WHERE media_id = 100 AND user_id = 2").Scan(&finished); err != nil || !finished {
		t.Fatalf("movie: %v %v", finished, err)
	}
	entry.TMDBID = 999
	if code := send(entry, 2); code != 200 {
		t.Fatal(code)
	}
	entry.UpdatedAt = "invalid"
	if code := send(entry, 2); code != 400 {
		t.Fatal(code)
	}
	var count int
	database.DB.QueryRow("SELECT COUNT(*) FROM progressions WHERE user_id = 2").Scan(&count)
	if count != 2 {
		t.Fatalf("unexpected matches: %d", count)
	}
}
