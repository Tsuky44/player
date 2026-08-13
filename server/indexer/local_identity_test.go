package indexer

import (
	"os"
	"path/filepath"
	"testing"

	"project-player/server/models"
)

func TestExtractProviderIDs(t *testing.T) {
	tmdbID, imdbID, tvdbID := ExtractProviderIDs("Inception (2010) [tmdbid-27205] [imdbid-tt1375666]")
	if tmdbID != 27205 {
		t.Fatalf("tmdb = %d, want 27205", tmdbID)
	}
	if imdbID != "tt1375666" {
		t.Fatalf("imdb = %q, want tt1375666", imdbID)
	}
	if tvdbID != 0 {
		t.Fatalf("tvdb = %d, want 0", tvdbID)
	}

	tmdbID, _, _ = ExtractProviderIDs("Show Name (2018) {tmdb-1396}")
	if tmdbID != 1396 {
		t.Fatalf("brace tmdb = %d, want 1396", tmdbID)
	}
}

func TestResolveMovieLookupName_PrefersFolder(t *testing.T) {
	root := t.TempDir()
	movieDir := filepath.Join(root, "Inception (2010) [tmdbid-27205]")
	if err := os.MkdirAll(movieDir, 0o755); err != nil {
		t.Fatal(err)
	}
	video := filepath.Join(movieDir, "movie.mkv")
	got := ResolveMovieLookupName(video, root)
	if got != "Inception (2010) [tmdbid-27205]" {
		t.Fatalf("got %q", got)
	}

	loose := filepath.Join(root, "Loose.Film.2020.mkv")
	got = ResolveMovieLookupName(loose, root)
	if got != "Loose.Film.2020" {
		t.Fatalf("root-level file got %q", got)
	}
}

func TestReadNFOIdentity(t *testing.T) {
	dir := t.TempDir()
	nfoPath := filepath.Join(dir, "movie.nfo")
	content := `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>Inception</title>
  <year>2010</year>
  <tmdbid>27205</tmdbid>
  <uniqueid type="imdb">tt1375666</uniqueid>
</movie>`
	if err := os.WriteFile(nfoPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	hints := ReadNFOIdentity(nfoPath)
	if hints.TMDBID != 27205 {
		t.Fatalf("tmdb = %d", hints.TMDBID)
	}
	if hints.IMDbID != "tt1375666" {
		t.Fatalf("imdb = %q", hints.IMDbID)
	}
	if hints.Title != "Inception" {
		t.Fatalf("title = %q", hints.Title)
	}
	if hints.Year != 2010 {
		t.Fatalf("year = %d", hints.Year)
	}
}

func TestParseEpisodeNumbers_ExpandedPatterns(t *testing.T) {
	tests := []struct {
		name string
		in   string
		s, e int
	}{
		{"sxxexx", "Show.S01E02.mkv", 1, 2},
		{"dot", "Show.S01.E02.mkv", 1, 2},
		{"x", "Show.1x02.mkv", 1, 2},
		{"season episode", "Show Season 2 Episode 5.mkv", 2, 5},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s, e, ok := ParseEpisodeNumbers(tt.in)
			if !ok {
				t.Fatal("expected ok")
			}
			if s != tt.s || e != tt.e {
				t.Fatalf("got S%dE%d, want S%dE%d", s, e, tt.s, tt.e)
			}
		})
	}
}

func TestIsConfidentTMDBMatch(t *testing.T) {
	good := tmdbSearchResult{ID: 1, Title: "Inception", ReleaseDate: "2010-07-16"}
	if !isConfidentTMDBMatch(good, "Inception", 2010, models.TypeMovie, 1.6) {
		t.Fatal("expected confident match")
	}
	weak := tmdbSearchResult{ID: 2, Title: "Open Season", ReleaseDate: "2006-01-01"}
	if isConfidentTMDBMatch(weak, "Open.Something.Else", 2023, models.TypeMovie, 0.4) {
		t.Fatal("expected rejection of weak score")
	}
}

func TestCollectMovieLocalIdentity_PathID(t *testing.T) {
	root := t.TempDir()
	movieDir := filepath.Join(root, "Matrix Reloaded (2003) [tmdbid-604]")
	if err := os.MkdirAll(movieDir, 0o755); err != nil {
		t.Fatal(err)
	}
	video := filepath.Join(movieDir, "Matrix Reloaded (2003).mkv")
	if err := os.WriteFile(video, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	hints := CollectMovieLocalIdentity(video, root)
	if hints.TMDBID != 604 {
		t.Fatalf("tmdb = %d, want 604", hints.TMDBID)
	}
	if hints.Source != "path_id" {
		t.Fatalf("source = %q, want path_id", hints.Source)
	}
}
