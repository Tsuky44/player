package indexer

import (
	"os"
	"path/filepath"
	"testing"

	"project-player/server/models"
)

// --- Release year / title parsing -------------------------------------------

func TestParseReleaseFilename_KeepsNumbersThatAreNotYears(t *testing.T) {
	tests := []struct {
		raw       string
		wantTitle string
		wantYear  int
	}{
		{"Blade Runner 2049 (2017)", "Blade Runner 2049", 2017},
		{"Blade.Runner.2049.2017.1080p.BluRay.x264", "Blade Runner 2049", 2017},
		{"Blade.Runner.2049.1080p", "Blade Runner 2049", 0},
		{"1917 (2019)", "1917", 2019},
		{"1917.2019.MULTI.1080p.BluRay.x264-GROUP", "1917", 2019},
		{"2012.2009.1080p.BluRay.x264", "2012", 2009},
		{"2001.A.Space.Odyssey.1968.1080p", "2001 A Space Odyssey", 1968},
		{"300 (2006)", "300", 2006},
		{"Inception.2010.1080p.BluRay", "Inception", 2010},
		{"Interstellar", "Interstellar", 0},
		{"Le Loup de Wall Street (2013)", "Le Loup de Wall Street", 2013},
	}
	for _, tt := range tests {
		t.Run(tt.raw, func(t *testing.T) {
			parsed := ParseReleaseFilename(tt.raw, models.TypeMovie)
			if parsed.Title != tt.wantTitle {
				t.Errorf("title = %q, want %q", parsed.Title, tt.wantTitle)
			}
			if parsed.Year != tt.wantYear {
				t.Errorf("year = %d, want %d", parsed.Year, tt.wantYear)
			}
		})
	}
}

func TestParseReleaseFilename_TitleNeverEmpty(t *testing.T) {
	for _, raw := range []string{"1917 (2019)", "2012.2009.1080p", "300.2006.MULTI.1080p"} {
		if got := ParseReleaseFilename(raw, models.TypeMovie).Title; got == "" {
			t.Fatalf("%q parsed to an empty title — it would never be searched on TMDB", raw)
		}
	}
}

func TestParseReleaseFilename_ShowKeepsYearHandling(t *testing.T) {
	parsed := ParseReleaseFilename("Mercredi.2022.S01E01.1080p.WEB-DL.mkv", models.TypeShow)
	if parsed.Title != "Mercredi" || parsed.Year != 2022 {
		t.Fatalf("got title=%q year=%d, want Mercredi/2022", parsed.Title, parsed.Year)
	}
}

// --- Movie identity: folder vs filename --------------------------------------

func writeVideo(t *testing.T, dir, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestResolveMovieLookupName_CategoryFolderNeverNamesMovie(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()

	cases := []struct {
		name   string
		folder string
		file   string
		want   string
	}{
		{"genre folder", "Action", "Inception.2010.1080p.mkv", "Inception.2010.1080p"},
		{"alphabet folder", "A", "Avatar.2009.mkv", "Avatar.2009"},
		{"quality folder", "4K", "Dune.2021.2160p.mkv", "Dune.2021.2160p"},
		{"language folder", "VF", "Alien.1979.mkv", "Alien.1979"},
		{"saga folder", "Saga Harry Potter", "HP1.2001.mkv", "HP1.2001"},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			dir := filepath.Join(root, tt.folder)
			video := writeVideo(t, dir, tt.file)
			if got := ResolveMovieLookupName(video, root); got != tt.want {
				t.Fatalf("lookup = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestResolveMovieLookupName_FolderWithSeveralMoviesNamesNone(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Le Seigneur des Anneaux")
	first := writeVideo(t, dir, "La.Communaute.de.l.Anneau.2001.mkv")
	writeVideo(t, dir, "Les.Deux.Tours.2002.mkv")
	writeVideo(t, dir, "Le.Retour.du.Roi.2003.mkv")

	if got := ResolveMovieLookupName(first, root); got != "La.Communaute.de.l.Anneau.2001" {
		t.Fatalf("lookup = %q — a folder holding 3 films must not name them", got)
	}
}

func TestResolveMovieLookupName_SingleMovieFolderStillWins(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Inception (2010)")
	video := writeVideo(t, dir, "movie.mkv")
	if got := ResolveMovieLookupName(video, root); got != "Inception (2010)" {
		t.Fatalf("lookup = %q, want the folder name", got)
	}
}

func TestResolveMovieLookupName_MultipartFolderIsOneMovie(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Titanic (1997)")
	first := writeVideo(t, dir, "Titanic.cd1.avi")
	writeVideo(t, dir, "Titanic.cd2.avi")
	if got := ResolveMovieLookupName(first, root); got != "Titanic (1997)" {
		t.Fatalf("lookup = %q, want the folder name (cd1+cd2 are one film)", got)
	}
}

func TestResolveMovieLookupName_IgnoresSamplesWhenCounting(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Arrival (2016)")
	video := writeVideo(t, dir, "Arrival.2016.1080p.mkv")
	writeVideo(t, dir, "sample.mkv")
	writeVideo(t, dir, "Arrival-trailer.mp4")
	if got := ResolveMovieLookupName(video, root); got != "Arrival (2016)" {
		t.Fatalf("lookup = %q, want the folder name (samples must not count)", got)
	}
}

// --- Episode numbering fallbacks ---------------------------------------------

func TestResolveEpisodeNumbers(t *testing.T) {
	tests := []struct {
		name  string
		parts []string
		file  string
		s, e  int
		ok    bool
	}{
		{"sxxexx wins", []string{"Show", "Saison 2", "Show.S02E05.mkv"}, "Show.S02E05.mkv", 2, 5, true},
		{"numbered file in season folder", []string{"Show", "Saison 2", "01 - Pilote.mkv"}, "01 - Pilote.mkv", 2, 1, true},
		{"season folder short form", []string{"Show", "S03", "04 - Titre.mkv"}, "04 - Titre.mkv", 3, 4, true},
		{"episode marker without season", []string{"Show", "Episode 7.mkv"}, "Episode 7.mkv", 1, 7, true},
		{"bare number file", []string{"Show", "Saison 1", "12.mkv"}, "12.mkv", 1, 12, true},
		{"dashed number", []string{"Kaamelott", "Kaamelott - 03 - Le Cas Yvain.mkv"}, "Kaamelott - 03 - Le Cas Yvain.mkv", 1, 3, true},
		{"quality is not an episode", []string{"Show", "Show.1080p.WEB-DL.mkv"}, "Show.1080p.WEB-DL.mkv", 0, 0, false},
		{"no episode info", []string{"Show", "Un film quelconque.mkv"}, "Un film quelconque.mkv", 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s, e, ok := ResolveEpisodeNumbers(tt.parts, tt.file)
			if ok != tt.ok {
				t.Fatalf("ok = %v, want %v", ok, tt.ok)
			}
			if ok && (s != tt.s || e != tt.e) {
				t.Fatalf("got S%dE%d, want S%dE%d", s, e, tt.s, tt.e)
			}
		})
	}
}

// --- Show identity in nested libraries ---------------------------------------

func TestResolveShowTitleFromPath_NestedCategories(t *testing.T) {
	tests := []struct {
		name  string
		parts []string
		want  string
	}{
		{"category folder", []string{"Animes", "Naruto", "Saison 1", "Naruto.S01E01.mkv"}, "Naruto"},
		{"language category", []string{"Séries VF", "Breaking Bad", "S01", "BB.S01E01.mkv"}, "Breaking Bad"},
		{"deep nesting", []string{"Animes", "Shonen", "One Piece", "Saison 1", "OP.S01E01.mkv"}, "One Piece"},
		{"numeric show", []string{"Séries", "24", "S01", "24.S01E01.mkv"}, "24"},
		{"flat layout", []string{"Breaking Bad", "BB.S01E01.mkv"}, "Breaking Bad"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			file := tt.parts[len(tt.parts)-1]
			if got := resolveShowTitleFromPath(tt.parts, file); got != tt.want {
				t.Fatalf("show title = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestResolveShowFolderPath_UsesDeepestShowFolder(t *testing.T) {
	got := resolveShowFolderPath("/media/Series", []string{"Animes", "Naruto", "Saison 1", "ep.mkv"})
	want := filepath.Join("/media/Series", "Animes", "Naruto")
	if got != want {
		t.Fatalf("show folder = %q, want %q", got, want)
	}
}

// --- TMDB match confidence ----------------------------------------------------

func TestTitleSimilarity_DiscriminatesPartialMatches(t *testing.T) {
	exact := titleSimilarity("alien", "alien")
	plural := titleSimilarity("alien", "aliens")
	unrelated := titleSimilarity("alien", "alien vs predator")

	if exact != 1.0 {
		t.Fatalf("exact = %.2f, want 1.0", exact)
	}
	if !(plural > unrelated) {
		t.Fatalf("«aliens» (%.2f) should rank above «alien vs predator» (%.2f)", plural, unrelated)
	}
	if unrelated >= minTitleScoreNoYear {
		t.Fatalf("«alien vs predator» scored %.2f — would be accepted for «alien»", unrelated)
	}
}

func TestIsConfidentTMDBMatch_RejectsWrongYearAndWeakTitles(t *testing.T) {
	bladeRunner1982 := tmdbSearchResult{ID: 78, Title: "Blade Runner", ReleaseDate: "1982-06-25"}
	if isConfidentTMDBMatch(bladeRunner1982, "Blade Runner 2049", 2017, models.TypeMovie, 1.4) {
		t.Fatal("Blade Runner (1982) must not match «Blade Runner 2049» (2017)")
	}

	bladeRunner2049 := tmdbSearchResult{ID: 335984, Title: "Blade Runner 2049", ReleaseDate: "2017-10-04"}
	if !isConfidentTMDBMatch(bladeRunner2049, "Blade Runner 2049", 2017, models.TypeMovie, 1.6) {
		t.Fatal("exact title + year must be accepted")
	}

	wrongYear := tmdbSearchResult{ID: 1, Title: "Inception", ReleaseDate: "1998-01-01"}
	if isConfidentTMDBMatch(wrongYear, "Inception", 2010, models.TypeMovie, 1.0) {
		t.Fatal("a 12-year year gap must be rejected")
	}
}

func TestIsConfidentTMDBMatch_TreatsAmpersandAsAnd(t *testing.T) {
	fastSeven := tmdbSearchResult{
		ID:          168259,
		Title:       "Fast & Furious 7",
		ReleaseDate: "2015-04-01",
	}

	if !isConfidentTMDBMatch(fastSeven, "fast and furious 7", 0, models.TypeMovie, 0) {
		t.Fatal("an ampersand title variant offered by manual search must also pass automatic matching")
	}
}

func TestIsConfidentTMDBMatch_UsesOriginalTitle(t *testing.T) {
	// French library, English release name: TMDB answers with the French title.
	frenchEntry := tmdbSearchResult{
		ID:            106646,
		Title:         "Le Loup de Wall Street",
		OriginalTitle: "The Wolf of Wall Street",
		ReleaseDate:   "2013-12-25",
	}
	if !isConfidentTMDBMatch(frenchEntry, "The Wolf of Wall Street", 2013, models.TypeMovie, 1.6) {
		t.Fatal("original title should carry the match")
	}
}

func TestIsConfidentTMDBMatch_NoYearNeedsNearExactTitle(t *testing.T) {
	loose := tmdbSearchResult{ID: 2, Title: "Alien vs Predator", ReleaseDate: "2004-08-12"}
	if isConfidentTMDBMatch(loose, "Alien", 0, models.TypeMovie, 0.9) {
		t.Fatal("without a year, a loose title match must be refused")
	}
	exact := tmdbSearchResult{ID: 348, Title: "Alien", ReleaseDate: "1979-05-25"}
	if !isConfidentTMDBMatch(exact, "Alien", 0, models.TypeMovie, 1.0) {
		t.Fatal("exact title without year should be accepted")
	}
}
