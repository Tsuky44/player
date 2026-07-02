package indexer

import (
	"testing"

	"project-player/server/models"
)

func TestParseReleaseFilename_Movie(t *testing.T) {
	parsed := ParseReleaseFilename("Open.Season.(2023).WEBDL-1080p.mkv", models.TypeMovie)
	if parsed.Year != 2023 {
		t.Fatalf("year = %d, want 2023", parsed.Year)
	}
	if parsed.Title != "Open Season" {
		t.Fatalf("title = %q, want %q", parsed.Title, "Open Season")
	}
}

func TestParseReleaseFilename_Show(t *testing.T) {
	parsed := ParseReleaseFilename("Lioness.S02E03.1080p.WEB-DL.x264-GROUP", models.TypeShow)
	if parsed.Title != "Lioness" {
		t.Fatalf("title = %q, want %q", parsed.Title, "Lioness")
	}
}

func TestBuildTMDBSearchQueries(t *testing.T) {
	parsed := ParsedReleaseName{Title: "The Lord of the Rings The Fellowship of the Ring"}
	queries := BuildTMDBSearchQueries(parsed)
	if len(queries) < 2 {
		t.Fatalf("expected at least 2 queries, got %v", queries)
	}
	if queries[len(queries)-1] != "The Lord of" {
		t.Fatalf("shortened query = %q, want %q", queries[len(queries)-1], "The Lord of")
	}
}

func TestStripReleaseTags_KeepsEpisodePattern(t *testing.T) {
	got := StripReleaseTags("Show.Name.S01E02.1080p.WEB-DL.mkv")
	if got == "Show Name" {
		t.Fatalf("StripReleaseTags should not cut at SxxExx, got %q", got)
	}
	if got != "Show Name S01E02" {
		t.Fatalf("got %q, want %q", got, "Show Name S01E02")
	}
}
