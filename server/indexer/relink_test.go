package indexer

import (
	"path/filepath"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func insertShow(t *testing.T, title string) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title) VALUES (?, ?)`, models.TypeShow, title,
	)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func insertSeason(t *testing.T, showID, number int) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, ?, ?, ?)`,
		models.TypeSeason, "Saison 1", showID, number,
	)
	if err != nil {
		t.Fatalf("insert season: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func insertEpisode(t *testing.T, seasonID int, title, path string) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, parent_id) VALUES (?, ?, ?, ?)`,
		models.TypeEpisode, title, path, seasonID,
	)
	if err != nil {
		t.Fatalf("insert episode: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func showTitleOfEpisode(t *testing.T, episodeID int) string {
	t.Helper()
	var title string
	err := database.DB.QueryRow(`
		SELECT show.title
		FROM medias ep
		JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
		JOIN medias show ON season.parent_id = show.id AND show.type = 'show'
		WHERE ep.id = ?`, episodeID).Scan(&title)
	if err != nil {
		t.Fatalf("show title of episode %d: %v", episodeID, err)
	}
	return title
}

// Episodes indexed before the fix all hang under the category folder ("Animes").
// Re-linking must file each one under its own series without touching row ids.
func TestRelinkEpisodesToShows_SplitsCategoryShow(t *testing.T) {
	setupMovieDB(t)
	root := "/media/Series"

	wrongShow := insertShow(t, "Animes")
	wrongSeason := insertSeason(t, wrongShow, 1)
	naruto := insertEpisode(t, wrongSeason, "S01E01", root+"/Animes/Naruto/Saison 1/Naruto.S01E01.mkv")
	onePiece := insertEpisode(t, wrongSeason, "S01E01", root+"/Animes/One Piece/Saison 1/OP.S01E01.mkv")

	if moved := RelinkEpisodesToShows(root); moved != 2 {
		t.Fatalf("moved = %d, want 2", moved)
	}

	if got := showTitleOfEpisode(t, naruto); got != "Naruto" {
		t.Fatalf("Naruto episode is under %q", got)
	}
	if got := showTitleOfEpisode(t, onePiece); got != "One Piece" {
		t.Fatalf("One Piece episode is under %q", got)
	}

	var leftovers int
	if err := database.DB.QueryRow(
		`SELECT COUNT(*) FROM medias WHERE type = 'show' AND title = 'Animes'`,
	).Scan(&leftovers); err != nil {
		t.Fatal(err)
	}
	if leftovers != 0 {
		t.Fatal("the emptied category show should have been cleaned up")
	}
}

func TestRelinkEpisodesToShows_LeavesCorrectHierarchyAlone(t *testing.T) {
	setupMovieDB(t)
	root := "/media/Series"

	show := insertShow(t, "Breaking Bad")
	season := insertSeason(t, show, 1)
	ep := insertEpisode(t, season, "S01E01", root+"/Breaking Bad/Saison 1/BB.S01E01.mkv")
	if _, err := database.DB.Exec(
		`UPDATE medias SET season_number = 1, episode_number = 1 WHERE id = ?`, ep,
	); err != nil {
		t.Fatal(err)
	}

	if moved := RelinkEpisodesToShows(root); moved != 0 {
		t.Fatalf("moved = %d, want 0 — a correct hierarchy must not be touched", moved)
	}
	if got := showTitleOfEpisode(t, ep); got != "Breaking Bad" {
		t.Fatalf("episode is under %q", got)
	}
}

func TestRelinkEpisodesToShows_IgnoresOtherLibraries(t *testing.T) {
	setupMovieDB(t)

	show := insertShow(t, "Animes")
	season := insertSeason(t, show, 1)
	ep := insertEpisode(t, season, "S01E01", filepath.ToSlash("/autre/chemin/Naruto/Saison 1/Naruto.S01E01.mkv"))

	if moved := RelinkEpisodesToShows("/media/Series"); moved != 0 {
		t.Fatalf("moved = %d, want 0 for a path outside the library root", moved)
	}
	if got := showTitleOfEpisode(t, ep); got != "Animes" {
		t.Fatalf("episode was moved to %q", got)
	}
}
