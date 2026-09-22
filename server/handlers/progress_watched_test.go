package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

// setupWatchedBatchTestDB builds one show, one season and [count] episodes of
// 1000 seconds each, and returns the season row id plus the episode ids.
func setupWatchedBatchTestDB(t *testing.T, count int) (seasonID int, episodeIDs []int) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	if _, err := database.InitDB(dbPath); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })

	if _, err := database.DB.Exec(
		"INSERT INTO users (id, username, password_hash) VALUES (1, 'test', 'hash')",
	); err != nil {
		t.Fatalf("insert user: %v", err)
	}

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title) VALUES (?, ?)", models.TypeShow, "Lioness",
	)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	showID, _ := res.LastInsertId()

	res, err = database.DB.Exec(
		"INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, ?, ?, ?)",
		models.TypeSeason, "Saison 1", showID, 1,
	)
	if err != nil {
		t.Fatalf("insert season: %v", err)
	}
	id, _ := res.LastInsertId()
	seasonID = int(id)

	for i := 1; i <= count; i++ {
		res, err = database.DB.Exec(
			`INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
			 VALUES (?, ?, ?, ?, ?, ?, ?)`,
			models.TypeEpisode, "Épisode "+strconv.Itoa(i),
			"/ep"+strconv.Itoa(i)+".mkv", 1000, seasonID, 1, i,
		)
		if err != nil {
			t.Fatalf("insert episode %d: %v", i, err)
		}
		epID, _ := res.LastInsertId()
		episodeIDs = append(episodeIDs, int(epID))
	}
	return seasonID, episodeIDs
}

func postWatchedBatch(t *testing.T, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	SetMediaWatchedBatch(rec,
		httptest.NewRequest(http.MethodPost, "/api/progress/watched", strings.NewReader(body)),
		nil, 1)
	return rec
}

func progressionOf(t *testing.T, mediaID int) (position int, finished bool) {
	t.Helper()
	err := database.DB.QueryRow(
		"SELECT current_position_seconds, is_finished FROM progressions WHERE user_id = 1 AND media_id = ?",
		mediaID,
	).Scan(&position, &finished)
	if err != nil {
		t.Fatalf("read progression of media %d: %v", mediaID, err)
	}
	return position, finished
}

func TestSetMediaWatchedBatch_MarksAWholeSeason(t *testing.T) {
	seasonID, episodes := setupWatchedBatchTestDB(t, 3)

	// La saison elle-même et un identifiant inconnu partent avec le lot : ils
	// sont ignorés plutôt que de faire échouer le geste.
	body := `{"watched": true, "media_ids": [` +
		strconv.Itoa(episodes[0]) + `,` +
		strconv.Itoa(episodes[1]) + `,` +
		strconv.Itoa(episodes[2]) + `,` +
		strconv.Itoa(seasonID) + `, 999999]}`

	rec := postWatchedBatch(t, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		Updated []watchedBatchEntry `json:"updated"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Updated) != len(episodes) {
		t.Fatalf("expected the %d episodes to be reported, got %d",
			len(episodes), len(resp.Updated))
	}

	for _, epID := range episodes {
		position, finished := progressionOf(t, epID)
		if !finished {
			t.Fatalf("episode %d should be finished", epID)
		}
		if position != 1000 {
			t.Fatalf("episode %d should sit at its duration, got %d", epID, position)
		}
	}
}

func TestSetMediaWatchedBatch_UnmarksAWholeSeason(t *testing.T) {
	_, episodes := setupWatchedBatchTestDB(t, 2)

	ids := strconv.Itoa(episodes[0]) + `,` + strconv.Itoa(episodes[1])
	if rec := postWatchedBatch(t,
		`{"watched": true, "media_ids": [`+ids+`]}`); rec.Code != http.StatusOK {
		t.Fatalf("marking the season: expected 200, got %d", rec.Code)
	}

	rec := postWatchedBatch(t, `{"watched": false, "media_ids": [`+ids+`]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	for _, epID := range episodes {
		position, finished := progressionOf(t, epID)
		if finished {
			t.Fatalf("episode %d should no longer be finished", epID)
		}
		// La position reste : « pas vu » n'est pas « jamais ouvert ».
		if position != 1000 {
			t.Fatalf("episode %d should keep its position, got %d", epID, position)
		}
	}
}

func TestSetMediaWatchedBatch_RejectsAnEmptyBatch(t *testing.T) {
	setupWatchedBatchTestDB(t, 1)

	if rec := postWatchedBatch(t, `{"watched": true, "media_ids": []}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an empty batch, got %d", rec.Code)
	}
}
