package indexer

import (
	"testing"

	"project-player/server/models"
)

func TestDedupeShowMediaListForDisplay_PrefersPoster(t *testing.T) {
	shows := []models.Media{
		{ID: 1, Type: models.TypeShow, Title: "Mercredi", TMDBID: 0, PosterURL: ""},
		{ID: 2, Type: models.TypeShow, Title: "Mercredi", TMDBID: 119051, PosterURL: "https://image.tmdb.org/t/p/w300/poster.jpg"},
	}
	out := DedupeShowMediaListForDisplay(shows)
	if len(out) != 1 {
		t.Fatalf("len = %d, want 1", len(out))
	}
	if out[0].PosterURL == "" {
		t.Fatal("expected merged row to keep a poster")
	}
}
