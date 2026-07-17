package handlers

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

func setupContinueWatchingTestDB(t *testing.T) (cleanup func()) {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "test.db")
	if _, err := database.InitDB(dbPath); err != nil {
		t.Fatalf("InitDB: %v", err)
	}

	_, err := database.DB.Exec(
		"INSERT INTO users (id, username, password_hash) VALUES (1, 'test', 'hash')",
	)
	if err != nil {
		t.Fatalf("insert user: %v", err)
	}

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, poster_url) VALUES (?, ?, ?)",
		models.TypeShow, "Lioness", "/show.jpg",
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
	seasonID, _ := res.LastInsertId()

	res, err = database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		models.TypeEpisode, "Cinq cent enfants", "/ep.mkv", 2820, seasonID, 1, 5,
	)
	if err != nil {
		t.Fatalf("insert episode: %v", err)
	}
	epID, _ := res.LastInsertId()

	_, err = database.DB.Exec(
		`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		 VALUES (1, ?, 254, 0, ?)`,
		epID, time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("insert progression: %v", err)
	}

	return func() {
		database.DB.Close()
		_ = os.RemoveAll(dir)
	}
}

func TestBuildShowContinueWatching_InProgressEpisode(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 show item, got %d", len(items))
	}
	if items[0].ShowTitle != "Lioness" {
		t.Fatalf("ShowTitle = %q, want Lioness", items[0].ShowTitle)
	}
	if items[0].EpisodeTitle != "Cinq cent enfants" {
		t.Fatalf("EpisodeTitle = %q", items[0].EpisodeTitle)
	}
	if items[0].CurrentPositionSeconds != 254 {
		t.Fatalf("position = %d, want 254", items[0].CurrentPositionSeconds)
	}
}

func TestBuildShowContinueWatching_BelowStartThreshold(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	_, err := database.DB.Exec(
		`UPDATE progressions
		 SET current_position_seconds = 120, is_finished = 0, updated_at = ?
		 WHERE user_id = 1`,
		time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("update progression: %v", err)
	}

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("expected 0 show items below threshold, got %d", len(items))
	}
}

func TestBuildShowContinueWatching_AtStartThreshold(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	_, err := database.DB.Exec(
		`UPDATE progressions
		 SET current_position_seconds = 282, is_finished = 0, updated_at = ?
		 WHERE user_id = 1`,
		time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("update progression: %v", err)
	}

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 show item at threshold, got %d", len(items))
	}
}

func TestBuildShowContinueWatching_AfterFinishedEpisode(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	// Mark the in-progress episode as finished.
	_, err := database.DB.Exec(
		`UPDATE progressions SET current_position_seconds = 2820, is_finished = 1, updated_at = ?
		 WHERE user_id = 1`,
		time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("update progression: %v", err)
	}

	var seasonID int64
	err = database.DB.QueryRow(
		`SELECT parent_id FROM medias WHERE type = ? LIMIT 1`, models.TypeEpisode,
	).Scan(&seasonID)
	if err != nil {
		t.Fatalf("get season: %v", err)
	}
	_, err = database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		models.TypeEpisode, "Épisode suivant", "/ep2.mkv", 3000, seasonID, 1, 6,
	)
	if err != nil {
		t.Fatalf("insert episode 2: %v", err)
	}

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 show item after finished episode, got %d", len(items))
	}
	if items[0].EpisodeTitle != "Épisode suivant" {
		t.Fatalf("EpisodeTitle = %q, want Épisode suivant", items[0].EpisodeTitle)
	}
	if items[0].CurrentPositionSeconds != 0 {
		t.Fatalf("position = %d, want 0 (next episode)", items[0].CurrentPositionSeconds)
	}
}

func TestBuildMovieContinueWatching_BelowStartThreshold(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration) VALUES (?, ?, ?, ?)`,
		models.TypeMovie, "Court métrage", "/short.mkv", 6000,
	)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	movieID, _ := res.LastInsertId()
	_, err = database.DB.Exec(
		`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		 VALUES (1, ?, 300, 0, ?)`,
		movieID, time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("insert movie progression: %v", err)
	}

	items, err := buildMovieContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildMovieContinueWatching: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("expected 0 movie items below threshold, got %d", len(items))
	}
}

func TestBuildMovieContinueWatching_AtStartThreshold(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration) VALUES (?, ?, ?, ?)`,
		models.TypeMovie, "Zootopie", "/movie.mkv", 6000,
	)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	movieID, _ := res.LastInsertId()
	_, err = database.DB.Exec(
		`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		 VALUES (1, ?, 600, 0, ?)`,
		movieID, time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("insert movie progression: %v", err)
	}

	items, err := buildMovieContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildMovieContinueWatching: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 movie item at threshold, got %d", len(items))
	}
}

func TestBuildContinueWatching_HiddenEntries(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	var showID int64
	err := database.DB.QueryRow(
		`SELECT id FROM medias WHERE type = ? LIMIT 1`, models.TypeShow,
	).Scan(&showID)
	if err != nil {
		t.Fatalf("get show id: %v", err)
	}

	_, err = database.DB.Exec(
		`INSERT INTO continue_watching_hidden (user_id, entry_key) VALUES (1, ?)`,
		continueWatchingShowKey(int(showID)),
	)
	if err != nil {
		t.Fatalf("insert hidden show: %v", err)
	}

	items, err := buildContinueWatching(1, 10)
	if err != nil {
		t.Fatalf("buildContinueWatching: %v", err)
	}
	for _, item := range items {
		if item.ShowTitle == "Lioness" {
			t.Fatalf("hidden show should not appear in continue watching")
		}
	}
}

func TestBuildContinueWatching_MovieAndShow(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration) VALUES (?, ?, ?, ?)`,
		models.TypeMovie, "Zootopie", "/movie.mkv", 6000,
	)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	movieID, _ := res.LastInsertId()
	_, err = database.DB.Exec(
		`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		 VALUES (1, ?, 1200, 0, ?)`,
		movieID, time.Now().UTC().Add(time.Minute).Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		t.Fatalf("insert movie progression: %v", err)
	}

	items, err := buildContinueWatching(1, 10)
	if err != nil {
		t.Fatalf("buildContinueWatching: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}
}

func TestResolveShowFromEpisode_DirectShowParent(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, poster_url) VALUES (?, ?, ?)",
		models.TypeShow, "Direct Show", "/direct.jpg",
	)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	showID, _ := res.LastInsertId()

	res, err = database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration, parent_id)
		 VALUES (?, ?, ?, ?, ?)`,
		models.TypeEpisode, "Pilot", "/pilot.mkv", 3600, showID,
	)
	if err != nil {
		t.Fatalf("insert episode: %v", err)
	}
	epID, _ := res.LastInsertId()

	gotID, gotTitle, _, ok := resolveShowFromEpisode(int(epID), int(showID))
	if !ok {
		t.Fatal("expected direct show resolution")
	}
	if gotID != int(showID) || gotTitle != "Direct Show" {
		t.Fatalf("resolveShowFromEpisode = (%d, %q), want (%d, Direct Show)", gotID, gotTitle, showID)
	}
}
