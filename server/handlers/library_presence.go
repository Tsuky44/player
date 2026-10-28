package handlers

import (
	"database/sql"
	"log"

	"project-player/server/database"
)

// Ce que la bibliothèque détient pèse plus que ce qu'OnyxHub en sait (ADR-0084).
//
// OnyxHub tire la disponibilité de Radarr et de Sonarr. Un titre ajouté à la
// main, ou par un autre outil, y est inconnu : OnyxHub répond « unknown » et la
// carte n'avait aucune pastille, alors que le titre est dans la bibliothèque
// d'Onyx, lisible. OnyxHub applique déjà cette règle sur ses propres cartes
// (son ADR-0010), mais il ne peut pas l'appliquer à la route que lit Onyx : un
// appel avec la clé d'intégration n'a pas de session pour lire l'index d'Onyx.
// Onyx connaît sa bibliothèque : c'est lui qui corrige.

// Et l'inverse : « disponible » ne se dit que si Onyx le voit. Un titre que le
// serveur de téléchargement a fini mais qu'Onyx n'a pas encore indexé est en
// cours d'import, pas lisible : la carte le dit « en cours » (ADR-0085).

const (
	requestStatusPartial    = "partial"
	requestStatusProcessing = "processing"
)

// withLibraryPresence : « unknown » devient « available » quand la
// bibliothèque détient le titre ; « available » et « partial » deviennent
// « processing » quand elle ne l'a pas. Un autre statut (demandé, en cours)
// vient d'OnyxHub et reste.
func withLibraryPresence(status string, held bool) string {
	switch {
	case held && (status == "" || status == requestStatusUnknown):
		return requestStatusAvailable
	case !held && (status == requestStatusAvailable || status == requestStatusPartial):
		return requestStatusProcessing
	}
	return status
}

// applyLibraryPresence corrige le statut de chaque carte d'après la
// bibliothèque, en une seule requête pour la page.
func applyLibraryPresence(items []catalogItem) {
	if len(items) == 0 {
		return
	}
	held := libraryHeldTMDB(items)
	if held == nil {
		return
	}
	for i := range items {
		items[i].Status = withLibraryPresence(items[i].Status, held[availabilityKey(items[i].MediaType, items[i].ID)])
	}
}

// libraryHeldTMDB dit, par availabilityKey, lesquelles des cartes la
// bibliothèque détient, ou nil si la base ne répond pas : les statuts d'OnyxHub restent
// alors tels quels, on ne dégrade rien sur une panne.
func libraryHeldTMDB(items []catalogItem) map[string]bool {
	ids := make([]any, 0, len(items))
	seen := make(map[int]bool, len(items))
	for _, item := range items {
		if item.ID > 0 && !seen[item.ID] {
			seen[item.ID] = true
			ids = append(ids, item.ID)
		}
	}
	held := map[string]bool{}
	if len(ids) == 0 {
		return held
	}

	rows, err := database.DB.Query(
		`SELECT DISTINCT type, tmdb_id FROM medias
		 WHERE type IN ('movie', 'show') AND tmdb_id IN (`+sqlPlaceholders(len(ids))+`)`, ids...)
	if err != nil {
		log.Printf("Library presence: %v", err)
		return nil
	}
	defer rows.Close()

	for rows.Next() {
		var mediaType string
		var tmdbID int
		if err := rows.Scan(&mediaType, &tmdbID); err != nil {
			log.Printf("Library presence scan: %v", err)
			return nil
		}
		// La base dit « show », le catalogue TMDB et OnyxHub disent « tv ».
		if mediaType == "show" {
			mediaType = "tv"
		}
		held[availabilityKey(mediaType, tmdbID)] = true
	}
	if err := rows.Err(); err != nil {
		log.Printf("Library presence rows: %v", err)
		return nil
	}
	return held
}

// heldShowSeasonEpisodes compte, par numéro de saison, les épisodes que la
// bibliothèque a d'une série repérée par son identifiant TMDB. Vide quand la
// série n'y est pas, nil si la base ne répond pas.
func heldShowSeasonEpisodes(tmdbID int) map[int]int {
	counts := map[int]int{}
	var showID sql.NullInt64
	err := database.DB.QueryRow(
		`SELECT MIN(id) FROM medias WHERE type = 'show' AND tmdb_id = ?`, tmdbID).Scan(&showID)
	if err != nil {
		log.Printf("Library presence show: %v", err)
		return nil
	}
	if !showID.Valid {
		return counts
	}
	seasons, err := loadLocalSeasons(int(showID.Int64))
	if err != nil {
		log.Printf("Library presence seasons: %v", err)
		return nil
	}
	byID := loadHeldEpisodeCounts(int(showID.Int64))
	for _, season := range seasons {
		if season.SeasonNumber > 0 {
			counts[season.SeasonNumber] += byID[season.ID]
		}
	}
	return counts
}

// seasonPresence : ce qu'Onyx a des épisodes d'une saison décide de
// « disponible » (tous), « partial » (entamée) ; quand OnyxHub la croit
// disponible ou partielle sans que le serveur ait un épisode, elle est « en
// cours » d'import. Un autre statut (demandé, en cours) reste.
func seasonPresence(status string, held, total int) string {
	switch status {
	case "", requestStatusUnknown, requestStatusAvailable, requestStatusPartial:
	default:
		return status
	}
	switch {
	case held <= 0 && status != requestStatusUnknown && status != "":
		return requestStatusProcessing
	case held <= 0:
		return requestStatusUnknown
	case total > 0 && held < total:
		return requestStatusPartial
	default:
		return requestStatusAvailable
	}
}

// showStatusFor : le statut d'une série d'après ses saisons. held dit si le
// serveur a au moins un épisode. « available » seulement si chaque saison
// l'est ; un statut de demande ou d'import d'OnyxHub (demandé, en cours) reste.
func showStatusFor(status string, held bool, seasonStatuses []string) string {
	if !held {
		return withLibraryPresence(status, false)
	}
	switch status {
	case "", requestStatusUnknown, requestStatusAvailable, requestStatusPartial:
	default:
		return status
	}
	for _, seasonStatus := range seasonStatuses {
		if seasonStatus != requestStatusAvailable {
			return requestStatusPartial
		}
	}
	return requestStatusAvailable
}
