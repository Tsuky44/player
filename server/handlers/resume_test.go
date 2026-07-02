package handlers

import (
	"testing"

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
