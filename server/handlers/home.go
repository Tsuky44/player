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
		ORDER BY m.created_at DESC, m.id DESC`, homeRecentMovies)
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
		JOIN (`+recentShowKeys+`) recent ON recent.show_id = m.id
		ORDER BY recent.last_added DESC, m.id DESC`, homeRecentShows*2)
	if err != nil {
		log.Printf("Home error: failed to query recent shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	// The query fetches more shows than the row holds because duplicate rows of
	// the same series collapse here, after the ordering.
	recentShows = indexer.DedupeShowMediaListForDisplay(recentShows)
	if len(recentShows) > homeRecentShows {
		recentShows = recentShows[:homeRecentShows]
	}

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
		ORDER BY MAX(created_at) DESC, MAX(id) DESC
		LIMIT ?`

// recentShowKeys orders series by the last file that landed under them.
//
// A series is not a file: it is created once, when its first episode is
// indexed, and never touched again. Ordering the row on the show row's own
// created_at therefore answered "which series did this server discover last",
// which freezes a series at the date of its first season — a show that just
// received a new season, the very thing worth showing on the home screen, kept
// the position it had a year ago and never came back.
//
// The recency of a series is the recency of its newest episode instead, with
// the show's own creation as the floor for one that has no episode yet. Both
// halves of what the row promises then fall out of one ordering: a series added
// today leads with its episodes, and an old one that gained files climbs back
// to the top.
//
// The direct-episode branch of the join covers libraries where episodes hang
// off the show without a season row; duplicate rows it may produce do not
// disturb a MAX.
const recentShowKeys = `
		SELECT s.id AS show_id,
		       MAX(COALESCE(ep.created_at, s.created_at)) AS last_added
		FROM medias s
		LEFT JOIN medias season ON season.type = 'season' AND season.parent_id = s.id
		LEFT JOIN medias ep ON ep.type = 'episode'
		                   AND (ep.parent_id = season.id OR ep.parent_id = s.id)
		WHERE s.type = 'show'
		GROUP BY s.id
		ORDER BY last_added DESC, s.id DESC
		LIMIT ?`

const discoveryMovieCardKeys = `
		SELECT COALESCE(NULLIF(tmdb_id, 0), -id)
		FROM medias
		WHERE type = 'movie' AND COALESCE(poster_url, '') != ''
		GROUP BY COALESCE(NULLIF(tmdb_id, 0), -id)
		ORDER BY RANDOM()
		LIMIT ?`
