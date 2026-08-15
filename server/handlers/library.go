package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// GetMovies returns all indexed movies (GET /api/movies)
func GetMovies(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	rows, err := database.DB.Query(`
		SELECT `+libraryItemColumns+`
		FROM medias m
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'movie'
		ORDER BY m.title ASC`, userID)
	if err != nil {
		log.Printf("Movies error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.HomeMediaItem{}
	for rows.Next() {
		item, err := scanLibraryItem(rows)
		if err != nil {
			log.Printf("Movies scan error: %v", err)
			continue
		}
		results = append(results, item)
	}

	json.NewEncoder(w).Encode(results)
}

// GetShows returns all indexed TV Shows (GET /api/shows)
func GetShows(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	results, err := queryMediaList("Shows", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'show'
		ORDER BY m.title ASC`)
	if err != nil {
		log.Printf("Shows error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	results = indexer.DedupeShowMediaListForDisplay(results)
	json.NewEncoder(w).Encode(results)
}

// GetSeasonEpisodes returns all episodes for a season, with watch progressions (GET /api/seasons/:id/episodes)
func GetSeasonEpisodes(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	seasonID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid season ID"}`, http.StatusBadRequest)
		return
	}

	indexer.RefreshSeasonEpisodesFromTMDB(seasonID)

	rows, err := database.DB.Query(`
		SELECT `+episodeItemColumns+`
		FROM medias m
		LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		ORDER BY COALESCE(NULLIF(m.episode_number, 0), 9999), m.id ASC`, userID, seasonID)
	if err != nil {
		log.Printf("Episodes error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.HomeMediaItem{}
	for rows.Next() {
		item, err := scanEpisodeItem(rows)
		if err != nil {
			log.Printf("Episodes scan error: %v", err)
			continue
		}
		results = append(results, item)
	}

	json.NewEncoder(w).Encode(results)
}
