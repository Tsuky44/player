package handlers

import (
	"testing"

	"project-player/server/models"
)

func localEpisode(id, number int) models.HomeMediaItem {
	return models.HomeMediaItem{Media: models.Media{
		ID: id, Type: models.TypeEpisode, FilePath: "/tv/e.mkv", EpisodeNumber: number,
	}}
}

// Une saison en cours de diffusion montre aussi les épisodes que le serveur
// n'a pas encore, rangés à leur place et marqués indisponibles.
func TestMergeMissingEpisodesAddsWhatTheServerLacks(t *testing.T) {
	local := []models.HomeMediaItem{localEpisode(11, 1), localEpisode(13, 3)}
	virtual := buildVirtualEpisodes(7, 2, []TMDBEpisodeSummary{
		{Number: 1, Name: "Un"},
		{Number: 2, Name: "Deux", AirDate: "2026-09-01"},
		{Number: 3, Name: "Trois"},
		{Number: 4, Name: "Quatre", AirDate: "2026-10-20"},
	})

	merged := mergeMissingEpisodes(local, virtual)

	want := []struct {
		id, number int
		available  bool
	}{{11, 1, true}, {0, 2, false}, {13, 3, true}, {0, 4, false}}
	if len(merged) != len(want) {
		t.Fatalf("got %d episodes, want %d", len(merged), len(want))
	}
	for i, w := range want {
		got := merged[i]
		if got.ID != w.id || got.EpisodeNumber != w.number || got.IsAvailable != w.available {
			t.Errorf("position %d: got id=%d number=%d available=%v, want %+v",
				i, got.ID, got.EpisodeNumber, got.IsAvailable, w)
		}
	}
	if merged[3].ReleaseDate != "2026-10-20" {
		t.Errorf("upcoming episode lost its air date: %q", merged[3].ReleaseDate)
	}
}

// Un épisode local sans numéro peut être n'importe lequel : rien n'est annoncé
// manquant plutôt que de doubler un épisode présent.
func TestMergeMissingEpisodesKeepsLocalOnlyWhenAnEpisodeIsUnnumbered(t *testing.T) {
	local := []models.HomeMediaItem{localEpisode(11, 1), localEpisode(12, 0)}
	virtual := buildVirtualEpisodes(7, 2, []TMDBEpisodeSummary{{Number: 1}, {Number: 2}})

	merged := mergeMissingEpisodes(local, virtual)

	if len(merged) != 2 || merged[0].ID != 11 || merged[1].ID != 12 {
		t.Fatalf("expected the local list untouched, got %+v", merged)
	}
}

func TestHeldSeasonRequest(t *testing.T) {
	cases := []struct {
		name        string
		statuses    map[int]string
		held, total int
		wantStatus  string
		wantRequest bool
	}{
		{"complète", map[int]string{}, 10, 10, requestStatusAvailable, false},
		{"incomplète, jamais demandée", map[int]string{}, 4, 10, requestStatusUnknown, true},
		{"incomplète, inconnue de MediaHub", map[int]string{2: "unknown"}, 4, 10, requestStatusUnknown, true},
		{"incomplète, déjà demandée", map[int]string{2: "pending"}, 4, 10, "pending", false},
		{"incomplète, en cours", map[int]string{2: "processing"}, 4, 10, "processing", false},
		{"incomplète, partielle chez MediaHub", map[int]string{2: "partial"}, 4, 10, "partial", false},
		{"incomplète, MediaHub la croit complète", map[int]string{2: "available"}, 4, 10, requestStatusAvailable, false},
		{"MediaHub injoignable", nil, 4, 10, requestStatusAvailable, false},
	}
	for _, c := range cases {
		status, canRequest := heldSeasonRequest(c.statuses, 2, c.held, c.total)
		if status != c.wantStatus || canRequest != c.wantRequest {
			t.Errorf("%s: got (%q, %v), want (%q, %v)",
				c.name, status, canRequest, c.wantStatus, c.wantRequest)
		}
	}
}
