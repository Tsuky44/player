package indexer

import (
	"os"
	"path/filepath"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func setupMovieDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
}

func insertMovie(t *testing.T, title, path string, tmdbID int) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, tmdb_id) VALUES (?, ?, ?, ?)`,
		models.TypeMovie, title, path, tmdbID,
	)
	if err != nil {
		t.Fatalf("insert movie %q: %v", title, err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func countMovies(t *testing.T) int {
	t.Helper()
	var n int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type = 'movie'`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func movieExists(t *testing.T, id int) bool {
	t.Helper()
	var exists bool
	if err := database.DB.QueryRow(
		`SELECT EXISTS(SELECT 1 FROM medias WHERE id = ?)`, id,
	).Scan(&exists); err != nil {
		t.Fatalf("exists: %v", err)
	}
	return exists
}

// Two different files sharing a TMDB id (alternate versions, or a bad match)
// must both survive: deleting one silently removed films from the library.
func TestDedupeDuplicateMovies_KeepsDistinctFiles(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	first := writeVideo(t, dir, "Dune.2021.1080p.mkv")
	second := writeVideo(t, dir, "Dune.2021.2160p.mkv")

	idA := insertMovie(t, "Dune", first, 438631)
	idB := insertMovie(t, "Dune", second, 438631)

	dedupeDuplicateMovies()

	if !movieExists(t, idA) || !movieExists(t, idB) {
		t.Fatalf("both files exist on disk — neither row may be deleted (%d/%d)", idA, idB)
	}
	if got := countMovies(t); got != 2 {
		t.Fatalf("movie count = %d, want 2", got)
	}
}

func TestDedupeDuplicateMovies_MergesSamePathRows(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	path := writeVideo(t, dir, "Arrival.2016.mkv")

	keep := insertMovie(t, "Arrival", path, 329865)
	dup := insertMovie(t, "Arrival", path, 329865)

	dedupeDuplicateMovies()

	if !movieExists(t, keep) {
		t.Fatal("canonical row was removed")
	}
	if movieExists(t, dup) {
		t.Fatal("duplicate row for the very same file should be merged")
	}
}

func TestDedupeDuplicateMovies_DropsStaleRowWhenFileIsGone(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	live := writeVideo(t, dir, "Heat.1995.mkv")
	gone := filepath.Join(dir, "Heat.1995.old.mkv")

	keep := insertMovie(t, "Heat", live, 949)
	stale := insertMovie(t, "Heat", gone, 949)

	if _, err := os.Stat(gone); err == nil {
		t.Fatal("test setup: stale path should not exist")
	}

	dedupeDuplicateMovies()

	if !movieExists(t, keep) {
		t.Fatal("row with a real file must be kept")
	}
	if movieExists(t, stale) {
		t.Fatal("row whose file disappeared should be merged away")
	}
}

// When every copy is missing (unmounted storage), nothing is deleted here —
// cleanup is the scanner's job and it has its own safety net.
func TestDedupeDuplicateMovies_KeepsAllWhenNoFileIsReachable(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	a := insertMovie(t, "Sicario", filepath.Join(dir, "a.mkv"), 273481)
	b := insertMovie(t, "Sicario", filepath.Join(dir, "b.mkv"), 273481)

	dedupeDuplicateMovies()

	if !movieExists(t, a) || !movieExists(t, b) {
		t.Fatal("no reachable file: rows must be left alone")
	}
}

func TestResolveCanonicalMovieID_DoesNotRedirectPlayableRows(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	first := writeVideo(t, dir, "Dune.2021.1080p.mkv")
	second := writeVideo(t, dir, "Dune.2021.2160p.mkv")

	insertMovie(t, "Dune", first, 438631)
	idB := insertMovie(t, "Dune", second, 438631)

	if got := ResolveCanonicalMovieID(idB); got != idB {
		t.Fatalf("canonical id = %d, want %d — a row with its own file must never point at another file", got, idB)
	}
}

func TestCleanMissingMedias_RefusesWhenLibraryRootIsUnreachable(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	for _, name := range []string{"a.mkv", "b.mkv", "c.mkv"} {
		insertMovie(t, name, filepath.Join(dir, name), 0)
	}

	beginScanReport(dir, "")
	if err := cleanMissingMedias(filepath.Join(dir, "does-not-exist")); err != nil {
		t.Fatalf("cleanMissingMedias: %v", err)
	}
	finishScanReport()

	if got := countMovies(t); got != 3 {
		t.Fatalf("movie count = %d, want 3 — an offline library root must not wipe the catalog", got)
	}
}

func TestCleanMissingMedias_RefusesMassDeletion(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	writeVideo(t, dir, "kept.mkv")
	insertMovie(t, "kept", filepath.Join(dir, "kept.mkv"), 0)
	for i := 0; i < 30; i++ {
		insertMovie(t, "ghost", filepath.Join(dir, "ghost", string(rune('a'+i))+".mkv"), 0)
	}

	beginScanReport(dir, "")
	if err := cleanMissingMedias(dir); err != nil {
		t.Fatalf("cleanMissingMedias: %v", err)
	}
	finishScanReport()

	if got := countMovies(t); got != 31 {
		t.Fatalf("movie count = %d, want 31 — losing 30/31 files means the storage is offline, not empty", got)
	}
}

func TestCleanMissingMedias_RemovesIsolatedMissingFile(t *testing.T) {
	setupMovieDB(t)
	dir := t.TempDir()
	for i := 0; i < 10; i++ {
		name := string(rune('a'+i)) + ".mkv"
		writeVideo(t, dir, name)
		insertMovie(t, name, filepath.Join(dir, name), 0)
	}
	gone := insertMovie(t, "deleted", filepath.Join(dir, "deleted.mkv"), 0)

	beginScanReport(dir, "")
	if err := cleanMissingMedias(dir); err != nil {
		t.Fatalf("cleanMissingMedias: %v", err)
	}
	finishScanReport()

	if movieExists(t, gone) {
		t.Fatal("a genuinely deleted file should still be cleaned up")
	}
	if got := countMovies(t); got != 10 {
		t.Fatalf("movie count = %d, want 10", got)
	}
}
