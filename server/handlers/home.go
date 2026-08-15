package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Home returns the dashboard data for the home screen (GET /api/home)
func Home(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	// 1. Continue watching — in-progress movies + latest in-progress episode per show.
	continueWatching, err := buildContinueWatching(userID, 10)
	if err != nil {
		log.Printf("Home error: failed to build continue watching: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	// 2. Get "Recent Movies"
	recentMovies, err := queryMediaList("Home recent movies", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'movie'
		ORDER BY m.created_at DESC
		LIMIT 15`)
	if err != nil {
		log.Printf("Home error: failed to query recent movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	// 3. Get "Recent Shows" (TV Series)
	recentShows, err := queryMediaList("Home recent shows", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'show'
		ORDER BY m.created_at DESC
		LIMIT 15`)
	if err != nil {
		log.Printf("Home error: failed to query recent shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	recentShows = indexer.DedupeShowMediaListForDisplay(recentShows)

	discoveryMovies, err := queryRandomLibraryItems(models.TypeMovie, 40)
	if err != nil {
		log.Printf("Home error: failed to query discovery movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	discoveryShows, err := queryRandomLibraryItems(models.TypeShow, 40)
	if err != nil {
		log.Printf("Home error: failed to query discovery shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	discoveryShows = indexer.DedupeShowMediaListForDisplay(discoveryShows)

	// Respond
	json.NewEncoder(w).Encode(models.HomeResponse{
		ContinueWatching: continueWatching,
		RecentMovies:     recentMovies,
		RecentShows:      recentShows,
		DiscoveryMovies:  discoveryMovies,
		DiscoveryShows:   discoveryShows,
	})
}

// queryRandomLibraryItems picks a random sample of titles that have artwork,
// for the home "discovery" rows.
func queryRandomLibraryItems(mediaType models.MediaType, limit int) ([]models.Media, error) {
	return queryMediaList("Discovery "+string(mediaType), `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = ?
		  AND COALESCE(m.poster_url, '') != ''
		ORDER BY RANDOM()
		LIMIT ?`, string(mediaType), limit)
}
