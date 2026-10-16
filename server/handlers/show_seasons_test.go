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

func TestHeldSeasonsTakeTheirArtworkFromTMDB(t *testing.T) {
	local := []showSeasonPayload{
		{Media: mediaWithSeason(1, "Saison 1")},
		{Media: models.Media{Type: models.TypeSeason, Title: "Saison 2", SeasonNumber: 2, PosterURL: "/local.jpg", Overview: "Local"}},
		{Media: mediaWithSeason(0, "Bonus")},
	}
	tmdbSeasons := []TMDBSeasonSummary{
		{Number: 0, Overview: "Spéciaux", PosterPath: "/zero.jpg"},
		{Number: 1, Overview: "Le début", PosterPath: "/one.jpg", AirDate: "2020-01-01"},
		{Number: 2, Overview: "La suite", PosterPath: "/two.jpg", AirDate: "2021-01-01"},
	}

	fillHeldSeasonArtwork(local, tmdbSeasons)

	if got := local[0].PosterURL; got != "https://image.tmdb.org/t/p/w500/one.jpg" {
		t.Errorf("season 1 poster = %q", got)
	}
	if local[0].Overview != "Le début" || local[0].ReleaseDate != "2020-01-01" {
		t.Errorf("season 1 = %q / %q, want TMDB overview and air date", local[0].Overview, local[0].ReleaseDate)
	}
	if local[1].PosterURL != "/local.jpg" || local[1].Overview != "Local" {
		t.Errorf("season 2 lost what the database holds: %q / %q", local[1].PosterURL, local[1].Overview)
	}
	if local[1].ReleaseDate != "2021-01-01" {
		t.Errorf("season 2 air date = %q, want the TMDB one", local[1].ReleaseDate)
	}
	if local[2].PosterURL != "" || local[2].Overview != "" {
		t.Errorf("an unnumbered season must not borrow the specials' artwork")
	}
}
