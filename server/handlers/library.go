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
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
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

	rows.Close()
	results, err = groupMediaVersions(results)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Unable to load versions")
		return
	}
	writeETaggedJSON(w, r, results)
}

// showLibraryItem is a show row carrying the watch roll-up the catalog grid
// needs to tell "vu" from "en cours". The counts only ever cover the episodes
// the server actually holds: a show is complete once every episode on disk has
// been finished, whatever TMDB says the season should contain.
type showLibraryItem struct {
	models.Media
	AvailableEpisodeCount int `json:"available_episode_count"`
	WatchedEpisodeCount   int `json:"watched_episode_count"`
	StartedEpisodeCount   int `json:"started_episode_count"`
}

// showWatchStats is that roll-up for one show row, before duplicates are merged.
type showWatchStats struct {
	available int
	watched   int
	started   int
}

func (s *showWatchStats) add(other showWatchStats) {
	s.available += other.available
	s.watched += other.watched
	s.started += other.started
}

// GetShows returns all indexed TV Shows (GET /api/shows)
func GetShows(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	results, err := queryMediaList("Shows", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'show'
		ORDER BY m.title ASC`)
	if err != nil {
		log.Printf("Shows error: failed to query: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}

	stats, err := loadShowWatchStats(userID)
	if err != nil {
		// Losing the roll-up costs the pastille, not the catalog: the grid
		// still lists every show, just without its "vu / en cours" marker.
		log.Printf("Shows: watch stats unavailable: %v", err)
		stats = map[int]showWatchStats{}
	}

	writeETaggedJSON(w, r, buildShowLibraryItems(results, stats))
}

// loadShowWatchStats counts, per show row, the episodes present on disk and how
// many of them the caller finished or merely started.
//
// Episodes without a file are TMDB placeholders for what the server does not
// hold — counting them would leave a fully watched show one episode short
// forever.
func loadShowWatchStats(userID int) (map[int]showWatchStats, error) {
	rows, err := database.DB.Query(`
		SELECT season.parent_id,
		       COUNT(*),
		       SUM(CASE WHEN COALESCE(p.is_finished, 0) != 0 THEN 1 ELSE 0 END),
		       SUM(CASE WHEN COALESCE(p.is_finished, 0) = 0
		                 AND COALESCE(p.current_position_seconds, 0) > 0
		                THEN 1 ELSE 0 END)
		FROM medias m
		JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode'
		  AND m.file_path IS NOT NULL AND m.file_path != ''
		  AND season.parent_id IS NOT NULL
		GROUP BY season.parent_id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	stats := map[int]showWatchStats{}
	for rows.Next() {
		var showID int
		var entry showWatchStats
		if err := rows.Scan(&showID, &entry.available, &entry.watched, &entry.started); err != nil {
			log.Printf("Shows watch stats scan error: %v", err)
			continue
		}
		stats[showID] = entry
	}
	return stats, rows.Err()
}

// buildShowLibraryItems dedupes the list for display, then folds each duplicate's
// counts into the row that survives: a show split across two folders shows up
// once, so its progress has to be the sum of both halves.
func buildShowLibraryItems(shows []models.Media, stats map[int]showWatchStats) []showLibraryItem {
	grouped := map[string]showWatchStats{}
	for _, show := range shows {
		key := indexer.ShowDisplayGroupKey(show)
		entry := grouped[key]
		entry.add(stats[show.ID])
		grouped[key] = entry
	}

	display := indexer.DedupeShowMediaListForDisplay(shows)
	items := make([]showLibraryItem, 0, len(display))
	for _, show := range display {
		entry := grouped[indexer.ShowDisplayGroupKey(show)]
		items = append(items, showLibraryItem{
			Media:                 show,
			AvailableEpisodeCount: entry.available,
			WatchedEpisodeCount:   entry.watched,
			StartedEpisodeCount:   entry.started,
		})
	}
	return items
}

// GetSeasonEpisodes returns all episodes for a season, with watch progressions (GET /api/seasons/:id/episodes)
func GetSeasonEpisodes(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	seasonID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid season ID")
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
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
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

	rows.Close()
	results, err = groupMediaVersions(results)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Unable to load versions")
		return
	}
	json.NewEncoder(w).Encode(results)
}
