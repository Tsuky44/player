package handlers

import (
	"path/filepath"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func seedLibraryPresence(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "presence.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	exec := func(query string, args ...any) int {
		t.Helper()
		res, err := database.DB.Exec(query, args...)
		if err != nil {
			t.Fatalf("%s: %v", query, err)
		}
		id, _ := res.LastInsertId()
		return int(id)
	}
	exec(`INSERT INTO medias (type, title, file_path, tmdb_id) VALUES (?, 'Matrix', '/matrix.mkv', 603)`, models.TypeMovie)
	showID := exec(`INSERT INTO medias (type, title, tmdb_id) VALUES (?, 'Got', 1399)`, models.TypeShow)
	seasonID := exec(`INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, 'Saison 1', ?, 1)`, models.TypeSeason, showID)
	for episode := 1; episode <= 3; episode++ {
		exec(`INSERT INTO medias (type, title, file_path, parent_id, season_number, episode_number) VALUES (?, 'Ep', ?, ?, 1, ?)`,
			models.TypeEpisode, "/got/"+string(rune('0'+episode))+".mkv", seasonID, episode)
	}
}

// Un titre que la bibliothèque détient mais qu'OnyxHub ne connaît pas (ajouté à
// la main, hors Radarr et Sonarr) doit porter la pastille « disponible » ; ce
// qu'OnyxHub sait d'un titre (demandé, en cours) reste intact (ADR-0084).
func TestApplyLibraryPresenceFillsWhatOnyxHubDoesNotKnow(t *testing.T) {
	seedLibraryPresence(t)
	items := []catalogItem{
		{ID: 603, MediaType: "movie", Status: "unknown"},
		{ID: 1399, MediaType: "tv", Status: "unknown"},
		{ID: 1399, MediaType: "movie", Status: "unknown"}, // même identifiant, autre type
		{ID: 9, MediaType: "movie", Status: "unknown"},
		{ID: 603, MediaType: "movie", Status: "processing"},
		{ID: 9, MediaType: "movie", Status: "available"},   // fini côté téléchargement, Onyx ne le voit pas
		{ID: 8, MediaType: "tv", Status: "partial"},        // idem pour une série entamée
		{ID: 603, MediaType: "movie", Status: "available"}, // Onyx le voit
		{ID: 7, MediaType: "movie", Status: "pending"},     // une demande reste une demande
	}

	applyLibraryPresence(items)

	want := []string{"available", "available", "unknown", "unknown", "processing", "processing", "processing", "available", "pending"}
	for i, item := range items {
		if item.Status != want[i] {
			t.Errorf("carte %d (%s %d) : statut %q, attendu %q", i, item.MediaType, item.ID, item.Status, want[i])
		}
	}
}

// Une saison entamée est « partielle », une saison complète « disponible » : la
// bibliothèque compte ses épisodes contre ceux de TMDB.
func TestHeldShowSeasonEpisodesFeedsSeasonPresence(t *testing.T) {
	seedLibraryPresence(t)

	held := heldShowSeasonEpisodes(1399)

	if held[1] != 3 {
		t.Fatalf("épisodes de la saison 1 : %d, attendu 3", held[1])
	}
	if got := seasonPresence("unknown", held[1], 3); got != "available" {
		t.Errorf("saison complète : %q", got)
	}
	if got := seasonPresence("unknown", held[1], 10); got != "partial" {
		t.Errorf("saison entamée : %q", got)
	}
	if got := seasonPresence("unknown", held[2], 8); got != "unknown" {
		t.Errorf("saison absente : %q", got)
	}
	if got := seasonPresence("pending", held[1], 3); got != "pending" {
		t.Errorf("le statut d'OnyxHub doit rester : %q", got)
	}
	if got := showStatusFor("unknown", true, []string{"available", "unknown"}); got != "partial" {
		t.Errorf("série dont une saison manque : %q", got)
	}
	if got := showStatusFor("unknown", true, []string{"available", "available"}); got != "available" {
		t.Errorf("série complète : %q", got)
	}
}

// OnyxHub dit « disponible » parce que le téléchargement est fini : tant
// qu'Onyx n'a pas l'épisode, la saison est « en cours » d'import, et une saison
// dont il manque des épisodes n'est que « partielle » (ADR-0085).
func TestAvailableMeansOnyxSeesIt(t *testing.T) {
	seedLibraryPresence(t)
	held := heldShowSeasonEpisodes(1399)

	if got := seasonPresence("available", held[2], 8); got != "processing" {
		t.Errorf("saison finie chez le téléchargeur, absente d'Onyx : %q", got)
	}
	if got := seasonPresence("available", held[1], 10); got != "partial" {
		t.Errorf("saison dont Onyx n'a que 3 épisodes sur 10 : %q", got)
	}
	if got := seasonPresence("available", held[1], 3); got != "available" {
		t.Errorf("saison qu'Onyx a en entier : %q", got)
	}
	if got := seasonPresence("processing", held[1], 3); got != "processing" {
		t.Errorf("un import en cours reste en cours : %q", got)
	}
	if got := showStatusFor("available", false, nil); got != "processing" {
		t.Errorf("série absente d'Onyx : %q", got)
	}
	if got := showStatusFor("processing", true, []string{"available", "processing"}); got != "processing" {
		t.Errorf("série dont une saison s'importe : %q", got)
	}
}
