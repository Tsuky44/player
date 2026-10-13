package indexer

import (
	"path/filepath"
	"testing"

	"project-player/server/libraries"
)

// Deux bibliothèques du même type, chacune dans son dossier : le serveur n'a
// pas « un dossier de films », il a celles qu'on lui déclare (ADR-0058).
func TestScan_EveryLibraryIsIndexedByItsKind(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	films, concerts, animes := t.TempDir(), t.TempDir(), t.TempDir()
	writeVideo(t, filepath.Join(films, "Dune (2021)"), "Dune.2021.mkv")
	writeVideo(t, filepath.Join(concerts, "Live at Pompeii (1972)"), "Live.at.Pompeii.1972.mkv")
	writeVideo(t, filepath.Join(animes, "Naruto", "Saison 1"), "Naruto.S01E01.mkv")

	libs := []libraries.Library{
		{Name: "Films", Kind: libraries.KindMovies, Path: films},
		{Name: "Concerts", Kind: libraries.KindMovies, Path: concerts},
		{Name: "Animés", Kind: libraries.KindShows, Path: animes},
	}
	beginScanReport("", "")
	for _, lib := range libs {
		scanLibraryScope(lib.Kind, fullScope(lib.Path))
	}
	finishScanReport()

	if got := countOfType(t, "movie"); got != 2 {
		t.Fatalf("movies = %d, want one per movies library", got)
	}
	if got := countOfType(t, "episode"); got != 1 {
		t.Fatalf("episodes = %d, want 1", got)
	}
	report := LastScanReport()
	if report.Movies.Indexed != 2 || report.Series.Indexed != 1 {
		t.Fatalf("report counts movies=%d series=%d, want 2 and 1", report.Movies.Indexed, report.Series.Indexed)
	}
}

// Supprimer une bibliothèque retire son catalogue : ses fichiers sont toujours
// sur le disque, aucun scan ne le ferait.
func TestForgetMediaUnder_RemovesTheLibraryAndNothingElse(t *testing.T) {
	setupMovieDB(t)
	insertMovie(t, "Dune", "/media/Films/Dune (2021)/Dune.mkv", 1)
	insertMovie(t, "Alien", "/media/Films/Alien (1979)/Alien.mkv", 2)
	insertMovie(t, "Akira", "/media/Films/Animation/Akira.mkv", 3)
	insertMovie(t, "Heat", "/media/Films 4K/Heat.mkv", 4)

	// « Animation » est une autre bibliothèque, emboîtée dans celle qu'on retire.
	remaining := []libraries.Library{
		{Kind: libraries.KindMovies, Path: "/media/Films/Animation"},
		{Kind: libraries.KindMovies, Path: "/media/Films 4K"},
	}
	removed, err := ForgetMediaUnder("/media/Films", remaining)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 2 {
		t.Fatalf("removed = %d, want the 2 films of the deleted library only", removed)
	}
	titles := titlesOfType(t, "movie")
	if len(titles) != 2 || titles[0] != "Akira" || titles[1] != "Heat" {
		t.Fatalf("movies left = %v, want [Akira Heat]", titles)
	}
}

func TestForgetMediaUnder_EmptiesTheShowsOfADeletedLibrary(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	animes, series := t.TempDir(), t.TempDir()
	writeVideo(t, filepath.Join(animes, "Naruto", "Saison 1"), "Naruto.S01E01.mkv")
	writeVideo(t, filepath.Join(series, "Kaamelott", "Saison 1"), "Kaamelott.S01E01.mkv")
	beginScanReport("", "")
	scanSeries(animes)
	scanSeries(series)
	finishScanReport()

	if _, err := ForgetMediaUnder(animes, []libraries.Library{{Kind: libraries.KindShows, Path: series}}); err != nil {
		t.Fatal(err)
	}
	shows := titlesOfType(t, "show")
	if len(shows) != 1 || shows[0] != "Kaamelott" {
		t.Fatalf("shows left = %v, want [Kaamelott] — a show with no episode left goes with them", shows)
	}
}

func TestMonitor_AFileBelongsToTheDeepestLibraryHoldingIt(t *testing.T) {
	sep := string(filepath.Separator)
	media := sep + "media"
	m := newLibraryMonitor(MonitorOptions{
		Roots: func() []libraries.Library {
			return []libraries.Library{
				{Name: "Tout", Kind: libraries.KindMovies, Path: media},
				{Name: "Animés", Kind: libraries.KindShows, Path: filepath.Join(media, "Animes")},
				{Name: "Docs", Kind: libraries.KindOther, Path: filepath.Join(media, "Docs")},
			}
		},
	})

	cases := []struct {
		path     string
		wantRoot string
		wantS    libraries.Kind
		wantOK   bool
	}{
		{filepath.Join(media, "Animes", "Naruto", "S01E01.mkv"), filepath.Join(media, "Animes"), libraries.KindShows, true},
		{filepath.Join(media, "Docs", "Cosmos.mkv"), filepath.Join(media, "Docs"), libraries.KindOther, true},
		{filepath.Join(media, "Dune.mkv"), media, libraries.KindMovies, true},
		// « Animes 2 » commence comme « Animes » sans en faire partie.
		{filepath.Join(media, "Animes 2", "x.mkv"), media, libraries.KindMovies, true},
		{sep + "ailleurs" + sep + "x.mkv", "", "", false},
	}
	for _, c := range cases {
		root, s, ok := m.rootFor(c.path)
		if root != c.wantRoot || s != c.wantS || ok != c.wantOK {
			t.Errorf("rootFor(%q) = %q, %v, %v; want %q, %v, %v", c.path, root, s, ok, c.wantRoot, c.wantS, c.wantOK)
		}
	}
}

// Renommer une bibliothèque ne change pas ce que le moniteur surveille : la
// carte des dossiers n'est pas jetée pour un changement de titre.
func TestMonitor_RenamingALibraryKeepsTheFolderMap(t *testing.T) {
	root := filepath.Join(string(filepath.Separator)+"media", "Films")
	name := "Films"
	m := newLibraryMonitor(MonitorOptions{
		Roots: func() []libraries.Library {
			return []libraries.Library{{ID: 1, Name: name, Kind: libraries.KindMovies, Path: root}}
		},
	})
	m.dirs[root] = dirState{}

	name = "Cinéma"
	m.checkRoots()
	if !m.isKnownDir(root) {
		t.Fatal("a rename dropped the folder map")
	}
}

// Une bibliothèque « autre » : chaque vidéo sous le nom de son fichier, sans
// que le serveur cherche à y reconnaître un film.
func TestScan_APlainLibraryKeepsFileNamesAndIsNeverIdentified(t *testing.T) {
	setupMovieDB(t)
	ResetDirScanCache()
	family, films := t.TempDir(), t.TempDir()
	writeVideo(t, filepath.Join(family, "2019"), "Noël 2019 chez mamie.mp4")
	writeVideo(t, filepath.Join(films, "Dune (2021)"), "Dune.2021.1080p.mkv")
	other, err := libraries.Create("Famille", libraries.KindOther, family)
	if err != nil {
		t.Fatal(err)
	}
	movies, err := libraries.Create("Films", libraries.KindMovies, films)
	if err != nil {
		t.Fatal(err)
	}

	beginScanReport("", "")
	scanLibraryScope(other.Kind, fullScope(other.Path))
	scanLibraryScope(movies.Kind, fullScope(movies.Path))
	finishScanReport()

	titles := titlesOfType(t, "movie")
	if len(titles) != 2 || titles[1] != "Noël 2019 chez mamie" {
		t.Fatalf("titles = %v, want the family video under its file name", titles)
	}
	if report := LastScanReport(); report.Movies.Unmatched != 1 || len(report.Unmatched) != 1 {
		t.Fatalf("unmatched = %d (%v), want only the film: a plain video has nothing to match",
			report.Movies.Unmatched, report.Unmatched)
	}

	// Les rattrapages TMDB ne la voient pas ; le film sans identité, si.
	queue := loadBackfillQueue()
	if len(queue) != 1 || queue[0].title == "Noël 2019 chez mamie" {
		t.Fatalf("backfill queue = %+v, want the film only", queue)
	}
	lower, _ := libraries.PathRange(family)
	if !InPlainLibrary(lower+"2019/Noël 2019 chez mamie.mp4") || InPlainLibrary(lower[:len(lower)-1]+" bis/x.mp4") {
		t.Fatal("InPlainLibrary does not follow the folder of the library")
	}
}
