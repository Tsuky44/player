package handlers

import (
	"testing"
	"time"

	"project-player/server/models"
)

func TestFindResumeEpisodeRow_AfterFinished(t *testing.T) {
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, isFinished: true, currentPosition: 100},
		{item: models.HomeMediaItem{Media: models.Media{ID: 2, Title: "E2"}}, isFinished: true, currentPosition: 100},
		{item: models.HomeMediaItem{Media: models.Media{ID: 3, Title: "E3"}}, isFinished: false, currentPosition: 0},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil || row.item.ID != 3 {
		t.Fatalf("expected episode 3, got %v ok=%v", row, ok)
	}
}

func TestFindResumeEpisodeRow_InProgressFirst(t *testing.T) {
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, isFinished: true},
		{item: models.HomeMediaItem{Media: models.Media{ID: 2, Title: "E2"}}, isFinished: false, currentPosition: 120},
		{item: models.HomeMediaItem{Media: models.Media{ID: 3, Title: "E3"}}, isFinished: false, currentPosition: 0},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil || row.item.ID != 2 {
		t.Fatalf("expected in-progress episode 2, got %v", row)
	}
}

// Un épisode abandonné en route au début de la série ne doit pas masquer celui
// qu'on regarde vraiment : la reprise suit le dernier épisode touché.
func TestFindResumeEpisodeRow_FollowsMostRecentlyWatched(t *testing.T) {
	base := time.Date(2026, 10, 1, 20, 0, 0, 0, time.UTC)
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, currentPosition: 600, lastUpdated: base},
		{item: models.HomeMediaItem{Media: models.Media{ID: 2, Title: "E2"}}, isFinished: true, currentPosition: 1400, lastUpdated: base.Add(time.Hour)},
		{item: models.HomeMediaItem{Media: models.Media{ID: 3, Title: "E3"}}, currentPosition: 300, lastUpdated: base.Add(2 * time.Hour)},
		{item: models.HomeMediaItem{Media: models.Media{ID: 4, Title: "E4"}}, lastUpdated: base.Add(48 * time.Hour)},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil || row.item.ID != 3 {
		t.Fatalf("expected the episode being watched (3), got %v ok=%v", row, ok)
	}
}

// Le dernier épisode regardé est terminé : la reprise est le premier non vu
// après lui, avec sa propre position, et pas un épisode entamé plus tôt.
func TestFindResumeEpisodeRow_NextUnwatchedAfterMostRecent(t *testing.T) {
	base := time.Date(2026, 10, 1, 20, 0, 0, 0, time.UTC)
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, currentPosition: 600, lastUpdated: base},
		{item: models.HomeMediaItem{Media: models.Media{ID: 2, Title: "E2"}}, isFinished: true, currentPosition: 1400, lastUpdated: base.Add(2 * time.Hour)},
		{item: models.HomeMediaItem{Media: models.Media{ID: 3, Title: "E3"}}, isFinished: true, currentPosition: 1400, lastUpdated: base.Add(time.Hour)},
		{item: models.HomeMediaItem{Media: models.Media{ID: 4, Title: "E4"}}},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil || row.item.ID != 4 {
		t.Fatalf("expected the next unwatched episode (4), got %v ok=%v", row, ok)
	}
}

func TestFindResumeEpisodeRow_SeriesComplete(t *testing.T) {
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, isFinished: true},
		{item: models.HomeMediaItem{Media: models.Media{ID: 2, Title: "E2"}}, isFinished: true},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if ok || row != nil {
		t.Fatalf("expected no resume episode when series complete, got %v ok=%v", row, ok)
	}
}

func TestFindResumeEpisodeRow_NeverStarted(t *testing.T) {
	episodes := []episodeProgressRow{
		{item: models.HomeMediaItem{Media: models.Media{ID: 1, Title: "E1"}}, isFinished: false, currentPosition: 0},
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil || row.item.ID != 1 {
		t.Fatalf("expected first episode, got %v", row)
	}
}
