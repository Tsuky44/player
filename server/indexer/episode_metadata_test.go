package indexer

import (
	"testing"
)

func TestParseEpisodeNumbers(t *testing.T) {
	s, e, ok := ParseEpisodeNumbers("Show.S02E03.1080p.WEB-DL.mkv")
	if !ok || s != 2 || e != 3 {
		t.Fatalf("ParseEpisodeNumbers = (%d, %d, %v), want (2, 3, true)", s, e, ok)
	}
}

func TestParseSeasonNumberFromTitle(t *testing.T) {
	if n := parseSeasonNumberFromTitle("Saison 4"); n != 4 {
		t.Fatalf("season = %d, want 4", n)
	}
}

func TestFallbackEpisodeTitle(t *testing.T) {
	got := fallbackEpisodeTitle(1, 5)
	if got != "Épisode 5" {
		t.Fatalf("got %q", got)
	}
}

func TestParseEpisodeNumbers_NoMatch(t *testing.T) {
	_, _, ok := ParseEpisodeNumbers("movie.mkv")
	if ok {
		t.Fatal("expected no match")
	}
}

func TestEpisodeNeedsTMDBRefresh(t *testing.T) {
	if !EpisodeNeedsTMDBRefresh("Lioness - S01E01 - Sacrificial Soldiers WEBDL-") {
		t.Fatal("expected filename-like title to need refresh")
	}
	if EpisodeNeedsTMDBRefresh("Soldats sacrificiels") {
		t.Fatal("expected TMDB title to not need refresh")
	}
}

func TestResolveEpisodeNumbersFromTitle(t *testing.T) {
	s, e, ok := ParseEpisodeNumbers("Lioness - S01E03 - Bruise Like a Fist WEBDL-")
	if !ok || s != 1 || e != 3 {
		t.Fatalf("ParseEpisodeNumbers from title = (%d,%d,%v)", s, e, ok)
	}
	season, ep := resolveEpisodeNumbers("", "Lioness - S01E03 - Bruise Like a Fist WEBDL-", "Saison 1", 0, 0)
	if season != 1 || ep != 3 {
		t.Fatalf("resolveEpisodeNumbers = (%d,%d), want (1,3)", season, ep)
	}
}
