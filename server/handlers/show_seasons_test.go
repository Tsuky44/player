package handlers

import (
	"testing"

	"project-player/server/models"
)

func mediaWithSeason(number int, title string) models.Media {
	return models.Media{Type: models.TypeSeason, Title: title, SeasonNumber: number}
}

func TestSeasonNumberFromTitle(t *testing.T) {
	cases := map[string]int{
		"Saison 3":     3,
		"saison 12":    12,
		"Season 1":     1,
		"S03":          3,
		"s3":           3,
		"  Saison 2  ": 2,
		"Saison":       0,
		"Spéciaux":     0,
		"":             0,
		"Saison 1 VF":  0, // ambiguous naming stays unnumbered rather than guessing
	}

	for title, want := range cases {
		if got := seasonNumberFromTitle(title); got != want {
			t.Errorf("seasonNumberFromTitle(%q) = %d, want %d", title, got, want)
		}
	}
}

func TestSortSeasonsOrdersByNumberAndKeepsUnnumberedLast(t *testing.T) {
	seasons := []showSeasonPayload{
		{Media: mediaWithSeason(0, "Bonus")},
		{Media: mediaWithSeason(3, "Saison 3")},
		{Media: mediaWithSeason(1, "Saison 1")},
		{Media: mediaWithSeason(2, "Saison 2")},
	}

	sortSeasons(seasons)

	want := []int{1, 2, 3, 0}
	for i, expected := range want {
		if seasons[i].SeasonNumber != expected {
			t.Fatalf("position %d: got season %d, want %d", i, seasons[i].SeasonNumber, expected)
		}
	}
}
