package indexer

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"project-player/server/database"
)

func titlesOfType(t *testing.T, mediaType string) []string {
	t.Helper()
	rows, err := database.DB.Query(`SELECT title FROM medias WHERE type = ?`, mediaType)
	if err != nil {
		t.Fatalf("query %s: %v", mediaType, err)
	}
	defer rows.Close()

	var titles []string
	for rows.Next() {
		var title string
		if err := rows.Scan(&title); err != nil {
			t.Fatal(err)
		}
		titles = append(titles, title)
	}
	sort.Strings(titles)
	return titles
}

func movieTitles(t *testing.T) []string {
	t.Helper()
	return titlesOfType(t, "movie")
}

// buildMovieLibrary lays out the folder shapes a real library mixes: films in
// their own folder, films in genre/alphabet folders, a saga folder, multi-part
// rips, extras and NAS junk.
func buildMovieLibrary(t *testing.T) (root string, wantFilms int) {
	t.Helper()
	root = t.TempDir()

	// Own folder (folder names the film)
	writeVideo(t, filepath.Join(root, "Inception (2010)"), "Inception.2010.1080p.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.mkv")
	// Own folder + bonus content that must not become films
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival-trailer.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)", "Extras"), "Making of.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.1080p.sample.mkv")

	// Genre / alphabet / quality folders holding several films each
	writeVideo(t, filepath.Join(root, "Action"), "Mad.Max.Fury.Road.2015.1080p.mkv")
	writeVideo(t, filepath.Join(root, "Action"), "John.Wick.2014.1080p.mkv")
	writeVideo(t, filepath.Join(root, "A"), "Avatar.2009.mkv")
	writeVideo(t, filepath.Join(root, "4K"), "Dune.2021.2160p.mkv")

	// Saga folder
	writeVideo(t, filepath.Join(root, "Saga Harry Potter"), "Harry.Potter.a.l.ecole.des.sorciers.2001.mkv")
	writeVideo(t, filepath.Join(root, "Saga Harry Potter"), "Harry.Potter.et.la.chambre.des.secrets.2002.mkv")
	writeVideo(t, filepath.Join(root, "Saga Harry Potter"), "Harry.Potter.et.le.prisonnier.d.azkaban.2004.mkv")

	// Loose files at the root, in less common containers
	writeVideo(t, root, "Heat.1995.m4v")
	writeVideo(t, root, "Casino.1995.ts")
	writeVideo(t, root, "Le.Fabuleux.Destin.d.Amelie.Poulain.2001.avi")

	// Titles that look like years
	writeVideo(t, filepath.Join(root, "Blade Runner 2049 (2017)"), "Blade.Runner.2049.2017.mkv")
	writeVideo(t, root, "1917.2019.MULTI.1080p.BluRay.x264-GROUP.mkv")

	// Multi-part rip: one film
	writeVideo(t, filepath.Join(root, "Titanic (1997)"), "Titanic.cd1.avi")
	writeVideo(t, filepath.Join(root, "Titanic (1997)"), "Titanic.cd2.avi")

	// Deeply nested and junk
	writeVideo(t, filepath.Join(root, "Divers", "Nouveautes", "2024"), "Furiosa.2024.1080p.mkv")
	writeVideo(t, filepath.Join(root, "@eaDir"), "thumbnail.mkv")
	writeVideo(t, filepath.Join(root, ".hidden"), "secret.mkv")
	if err := os.WriteFile(filepath.Join(root, "readme.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 2 own-folder + 4 category + 3 saga + 3 loose + 2 year-like + 1 multipart + 1 nested
	return root, 16
}

func TestScanMovies_IndexesEveryFilmExactlyOnce(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	root, wantFilms := buildMovieLibrary(t)

	beginScanReport(root, "")
	scanMovies(root)
	finishScanReport()

	titles := movieTitles(t)
	if len(titles) != wantFilms {
		t.Fatalf("indexed %d films, want %d\n%v", len(titles), wantFilms, titles)
	}

	report := LastScanReport()
	if report.Movies.Indexed != wantFilms {
		t.Fatalf("report says %d indexed, want %d", report.Movies.Indexed, wantFilms)
	}
	// Every video file is either indexed or explicitly accounted for as skipped.
	if report.Movies.VideoFiles != report.Movies.Indexed+report.Movies.Skipped {
		t.Fatalf("accounting mismatch: %d files = %d indexed + %d skipped",
			report.Movies.VideoFiles, report.Movies.Indexed, report.Movies.Skipped)
	}
}

func TestScanMovies_TitlesComeFromTheFilmNotTheFolder(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	root, _ := buildMovieLibrary(t)

	beginScanReport(root, "")
	scanMovies(root)
	finishScanReport()

	titles := movieTitles(t)
	joined := strings.Join(titles, "\n")

	for _, forbidden := range []string{"Action", "4K", "Saga Harry Potter", "Nouveautes", "Divers"} {
		for _, got := range titles {
			if got == forbidden {
				t.Errorf("a film was titled %q — the folder name leaked into the identity", forbidden)
			}
		}
	}

	for _, want := range []string{
		"Inception", "Arrival", "Mad Max Fury Road", "John Wick", "Avatar", "Dune",
		"Heat", "Casino", "Blade Runner 2049", "1917", "Titanic", "Furiosa",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing film %q in:\n%s", want, joined)
		}
	}
}

func TestScanMovies_IsIdempotent(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	root, wantFilms := buildMovieLibrary(t)

	for i := 0; i < 2; i++ {
		ResetDirScanCache()
		beginScanReport(root, "")
		scanMovies(root)
		finishScanReport()
	}

	if got := countMovies(t); got != wantFilms {
		t.Fatalf("after two scans: %d films, want %d", got, wantFilms)
	}
	if second := LastScanReport(); second.Movies.AlreadyIndexed != wantFilms {
		t.Fatalf("second scan re-indexed instead of skipping (%d already indexed)", second.Movies.AlreadyIndexed)
	}
}

func TestScanSeries_NestedLibraryKeepsShowsSeparate(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	root := t.TempDir()

	writeVideo(t, filepath.Join(root, "Animes", "Naruto", "Saison 1"), "Naruto.S01E01.mkv")
	writeVideo(t, filepath.Join(root, "Animes", "Naruto", "Saison 1"), "Naruto.S01E02.mkv")
	writeVideo(t, filepath.Join(root, "Animes", "One Piece", "Saison 1"), "OP.S01E01.mkv")
	writeVideo(t, filepath.Join(root, "Breaking Bad", "Season 2"), "BB.S02E05.mkv")
	// Numbered episodes without SxxExx in the filename
	writeVideo(t, filepath.Join(root, "Kaamelott", "Saison 1"), "01 - Heat.mkv")
	writeVideo(t, filepath.Join(root, "Kaamelott", "Saison 1"), "02 - Le Serpent Geant.mkv")

	beginScanReport("", root)
	scanSeries(root)
	finishScanReport()

	shows := titlesOfType(t, "show")
	want := []string{"Breaking Bad", "Kaamelott", "Naruto", "One Piece"}
	if len(shows) != len(want) {
		t.Fatalf("shows = %v, want %v", shows, want)
	}
	for i := range want {
		if shows[i] != want[i] {
			t.Fatalf("shows = %v, want %v", shows, want)
		}
	}

	var episodes int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type = 'episode'`).Scan(&episodes); err != nil {
		t.Fatal(err)
	}
	if episodes != 6 {
		t.Fatalf("episodes = %d, want 6", episodes)
	}
}
