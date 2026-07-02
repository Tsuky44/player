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

	items, err := buildShowContinueWatching(1)
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
