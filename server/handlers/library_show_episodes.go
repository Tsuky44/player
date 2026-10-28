package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// Les épisodes qu'une série a vraiment, par identifiant TMDB (ADR-0082).
//
// OnyxHub montre les épisodes d'une saison d'après TMDB et doit dire lesquels
// se lisent. Il le demandait à sorraa ou à Sonarr, qui disent ce qui a été
// importé, pas ce qu'Onyx a indexé : un épisode ajouté à la main restait
// « manquant ». /api/shows/:id/seasons et /api/seasons/:id/episodes rendent
// des fiches complètes, et complètent par TMDB : trop pour une question qui
// ne porte que sur des numéros.

type libraryShowEpisodes struct {
	// Seasons associe un numéro de saison (en texte : clé JSON) aux numéros
	// d'épisodes lisibles, du plus petit au plus grand.
	Seasons map[string][]int `json:"seasons"`
}

func loadLibraryShowEpisodes(tmdbID int) (libraryShowEpisodes, error) {
	result := libraryShowEpisodes{Seasons: map[string][]int{}}
	// Plusieurs fiches de série peuvent porter le même identifiant TMDB (deux
	// dossiers) : leurs épisodes s'additionnent. Un épisode sans fichier n'est
	// pas lisible (comme IsAvailable dans show_season_episodes.go).
	rows, err := database.DB.Query(`
		SELECT DISTINCT season.season_number, ep.episode_number
		FROM medias show_m
		JOIN medias season ON season.parent_id = show_m.id AND season.type = 'season'
		JOIN medias ep ON ep.parent_id = season.id AND ep.type = 'episode'
		WHERE show_m.type = 'show' AND show_m.tmdb_id = ?
		  AND ep.episode_number > 0 AND COALESCE(ep.file_path, '') <> ''
		ORDER BY season.season_number, ep.episode_number`, tmdbID)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var season, episode int
		if err := rows.Scan(&season, &episode); err != nil {
			return result, err
		}
		key := strconv.Itoa(season)
		result.Seasons[key] = append(result.Seasons[key], episode)
	}
	return result, rows.Err()
}

// GetLibraryShowEpisodes rend les épisodes lisibles d'une série
// (GET /api/library/shows/:tmdb/episodes).
func GetLibraryShowEpisodes(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, _ int) {
	tmdbID, err := strconv.Atoi(ps.ByName("tmdb"))
	if err != nil || tmdbID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid TMDB ID")
		return
	}
	result, err := loadLibraryShowEpisodes(tmdbID)
	if err != nil {
		log.Printf("GetLibraryShowEpisodes: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}
