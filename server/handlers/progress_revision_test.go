package handlers

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func readProgressRevision(t *testing.T, userID int) string {
	t.Helper()
	w := httptest.NewRecorder()
	GetProgressRevision(w, httptest.NewRequest("GET", "/api/progress/revision", nil), nil, userID)
	if w.Code != 200 {
		t.Fatalf("revision: %d %s", w.Code, w.Body.String())
	}
	var resp models.ProgressRevision
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode revision: %v", err)
	}
	return resp.Revision
}

// Un écran ouvert ne relit ses données que si le jeton a bougé : il doit donc
// bouger à chaque chose qu'un autre appareil peut faire, et rester immobile
// sinon — y compris quand c'est un autre compte qui regarde.
func TestProgressRevisionChangesWithWhatTheAccountWatched(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	if _, err := database.DB.Exec(
		"INSERT INTO users (id, username, password_hash) VALUES (2, 'other', 'hash')",
	); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	var episodeID, showID int
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE type = 'episode'").Scan(&episodeID); err != nil {
		t.Fatalf("find episode: %v", err)
	}
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE type = 'show'").Scan(&showID); err != nil {
		t.Fatalf("find show: %v", err)
	}
	post := func(userID int, handler AuthenticatedHandle, body interface{}) {
		t.Helper()
		raw, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		handler(w, httptest.NewRequest("POST", "/", bytes.NewReader(raw)), nil, userID)
		if w.Code != 200 {
			t.Fatalf("post: %d %s", w.Code, w.Body.String())
		}
	}

	start := readProgressRevision(t, 1)
	if again := readProgressRevision(t, 1); again != start {
		t.Fatalf("revision moved without a write: %q then %q", start, again)
	}

	post(1, UpdateProgress, ProgressRequest{MediaID: episodeID, CurrentPositionSeconds: 600, Duration: 2820})
	afterHeartbeat := readProgressRevision(t, 1)
	if afterHeartbeat == start {
		t.Fatal("a heartbeat from another device did not move the revision")
	}

	post(1, HideFromContinueWatching, map[string]int{"show_id": showID})
	afterHide := readProgressRevision(t, 1)
	if afterHide == afterHeartbeat {
		t.Fatal("hiding a continue-watching entry did not move the revision")
	}

	if _, err := database.DB.Exec("DELETE FROM progressions WHERE user_id = 1"); err != nil {
		t.Fatalf("delete progress: %v", err)
	}
	if afterDelete := readProgressRevision(t, 1); afterDelete == afterHide {
		t.Fatal("deleted progress did not move the revision")
	}

	otherStart := readProgressRevision(t, 2)
	post(1, UpdateProgress, ProgressRequest{MediaID: episodeID, CurrentPositionSeconds: 900, Duration: 2820})
	if got := readProgressRevision(t, 2); got != otherStart {
		t.Fatalf("another account's playback moved this revision: %q then %q", otherStart, got)
	}
}
