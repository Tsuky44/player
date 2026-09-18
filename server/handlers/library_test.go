package handlers

import (
	"testing"

	"project-player/server/models"
)

// A show split over two folders is one card on screen, so the pastille has to
// read the two halves together: 3 of 4 episodes watched, not 2 of 2 and 1 of 2.
func TestBuildShowLibraryItemsMergesDuplicateShowCounts(t *testing.T) {
	shows := []models.Media{
		{ID: 1, Type: models.TypeShow, Title: "Severance"},
		{ID: 2, Type: models.TypeShow, Title: "Severance"},
	}
	stats := map[int]showWatchStats{
		1: {available: 2, watched: 2},
		2: {available: 2, watched: 1, started: 1},
	}

	items := buildShowLibraryItems(shows, stats)

	if len(items) != 1 {
		t.Fatalf("got %d rows, want the duplicates merged into one", len(items))
	}
	got := items[0]
	if got.AvailableEpisodeCount != 4 || got.WatchedEpisodeCount != 3 || got.StartedEpisodeCount != 1 {
		t.Fatalf("got %d/%d watched (%d started), want 3/4 (1 started)",
			got.WatchedEpisodeCount, got.AvailableEpisodeCount, got.StartedEpisodeCount)
	}
}

// A show nobody has opened still ships its episode count: the client needs it
// to tell "rien commencé" from "série vide".
func TestBuildShowLibraryItemsKeepsUntouchedShows(t *testing.T) {
	shows := []models.Media{{ID: 7, Type: models.TypeShow, Title: "Andor"}}

	items := buildShowLibraryItems(shows, map[int]showWatchStats{7: {available: 12}})

	if len(items) != 1 {
		t.Fatalf("got %d rows, want 1", len(items))
	}
	if items[0].AvailableEpisodeCount != 12 || items[0].WatchedEpisodeCount != 0 {
		t.Fatalf("got %d/%d watched, want 0/12",
			items[0].WatchedEpisodeCount, items[0].AvailableEpisodeCount)
	}
}
