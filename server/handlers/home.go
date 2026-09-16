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
		  AND `+movieCardKey("m")+` IN (`+recentMovieCardKeys+`)
		ORDER BY m.created_at DESC`, homeRecentMovies)
	if err != nil {
		log.Printf("Home error: failed to query recent movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	recentMovies, err = groupMovieCards(recentMovies)
	if err != nil {
		http.Error(w, `{"error":"Unable to load versions"}`, http.StatusInternalServerError)
		return
	}
	if len(recentMovies) > homeRecentMovies {
		recentMovies = recentMovies[:homeRecentMovies]
	}

	// 3. Get "Recent Shows" (TV Series)
	recentShows, err := queryMediaList("Home recent shows", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'show'
		ORDER BY m.created_at DESC
		LIMIT ?`, homeRecentShows)
	if err != nil {
		log.Printf("Home error: failed to query recent shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	recentShows = indexer.DedupeShowMediaListForDisplay(recentShows)

	discoveryMovies, err := queryRandomLibraryItems(models.TypeMovie, homeDiscoveryItems)
	if err != nil {
		log.Printf("Home error: failed to query discovery movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	discoveryShows, err := queryRandomLibraryItems(models.TypeShow, homeDiscoveryItems)
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
	if mediaType == models.TypeMovie {
		// The rows are drawn from a bounded set of cards rather than from the
		// whole table — see recentMovieCardKeys for why the sampling has to
		// happen on the grouping key.
		items, err := queryMediaList("Discovery movies", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'movie'
		  AND COALESCE(m.poster_url, '') != ''
		  AND `+movieCardKey("m")+` IN (`+discoveryMovieCardKeys+`)
		ORDER BY RANDOM()`, limit)
		if err != nil {
			return nil, err
		}
		items, err = groupMovieCards(items)
		if err != nil {
			return nil, err
		}
		if len(items) > limit {
			items = items[:limit]
		}
		return items, nil
	}
	return queryMediaList("Discovery "+string(mediaType), `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = ?
		  AND COALESCE(m.poster_url, '') != ''
		ORDER BY RANDOM()
		LIMIT ?`, string(mediaType), limit)
}

// Home row sizes. They bound the SQL below, so they are not free-floating
// magic numbers any more.
const (
	homeRecentMovies   = 15
	homeRecentShows    = 15
	homeDiscoveryItems = 40
)

// movieCardKey is versionGroupKey's movie branch, expressed in SQL.
//
// A card is one film, and several files of the same film collapse into it, so
// the unit these rows are counted in is the group and not the row. Identified
// films group on tmdb_id; an unidentified one is its own card, keyed by its id
// and negated so the two id spaces cannot collide.
func movieCardKey(alias string) string {
	return "COALESCE(NULLIF(" + alias + ".tmdb_id, 0), -" + alias + ".id)"
}

// recentMovieCardKeys and discoveryMovieCardKeys pick the cards a row is
// allowed to belong to, before any row is read.
//
// Both queries used to run unbounded — every film in the library was sorted,
// hydrated into a struct and passed through groupMovieCards, and only then cut
// down to the fifteen or forty the screen shows. The cost of opening the home
// screen grew with the size of the library, on every request, for every user.
//
// The limit cannot simply move into the outer query: it counts cards, and the
// grouping that produces cards happens in Go. So the keys are chosen first, in
// a subquery that reads no columns beyond the key itself, and the outer query
// then loads only the rows belonging to them.
//
// MAX(created_at) is what "recent" means for a card whose files were added at
// different times: the group sorts by its newest file, which is the position
// the old first-appearance ordering gave it.
const recentMovieCardKeys = `
		SELECT COALESCE(NULLIF(tmdb_id, 0), -id)
		FROM medias
		WHERE type = 'movie'
		GROUP BY COALESCE(NULLIF(tmdb_id, 0), -id)
		ORDER BY MAX(created_at) DESC
		LIMIT ?`

const discoveryMovieCardKeys = `
		SELECT COALESCE(NULLIF(tmdb_id, 0), -id)
		FROM medias
		WHERE type = 'movie' AND COALESCE(poster_url, '') != ''
		GROUP BY COALESCE(NULLIF(tmdb_id, 0), -id)
		ORDER BY RANDOM()
		LIMIT ?`
