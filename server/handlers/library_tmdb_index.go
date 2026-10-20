package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// Ce que la bibliothèque a, par identifiant TMDB (ADR-0073).
//
// OnyxHub montre le catalogue TMDB : il a besoin de savoir, pour chaque carte,
// si Onyx a déjà le titre, et quelle fiche ouvrir pour le lire. Il le
// demandait à Radarr et Sonarr, qui disent ce qui est sur le disque, pas ce
// qu'Onyx a indexé. /api/media-identities rend chaque épisode : trop pour une
// question qui ne porte que sur des films et des séries.

type libraryTMDBIndex struct {
	// Movies et Shows associent un identifiant TMDB (en texte : clé JSON) à la
	// fiche du serveur. Un film en plusieurs versions donne la plus ancienne,
	// comme le rattachement des listes (ADR-0070).
	Movies map[string]int `json:"movies"`
	Shows  map[string]int `json:"shows"`
}

func loadLibraryTMDBIndex() (libraryTMDBIndex, error) {
	index := libraryTMDBIndex{Movies: map[string]int{}, Shows: map[string]int{}}
	rows, err := database.DB.Query(`
		SELECT type, tmdb_id, MIN(id) FROM medias
		WHERE type IN ('movie', 'show') AND tmdb_id > 0
		GROUP BY type, tmdb_id`)
	if err != nil {
		return index, err
	}
	defer rows.Close()
	for rows.Next() {
		var mediaType string
		var tmdbID, id int
		if err := rows.Scan(&mediaType, &tmdbID, &id); err != nil {
			return index, err
		}
		if mediaType == "movie" {
			index.Movies[strconv.Itoa(tmdbID)] = id
		} else {
			index.Shows[strconv.Itoa(tmdbID)] = id
		}
	}
	return index, rows.Err()
}

// GetLibraryTMDBIndex rend les films et séries de la bibliothèque par
// identifiant TMDB (GET /api/library/tmdb-index).
func GetLibraryTMDBIndex(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, _ int) {
	index, err := loadLibraryTMDBIndex()
	if err != nil {
		log.Printf("GetLibraryTMDBIndex: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(index)
}
