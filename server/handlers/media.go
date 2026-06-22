package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// DebugIntroOutro returns all episodes with intro/outro data for debugging
func DebugIntroOutro(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	type EpisodeDebug struct {
		ID         int    `json:"id"`
		Title      string `json:"title"`
		IntroStart int    `json:"intro_start"`
		IntroEnd   int    `json:"intro_end"`
		OutroStart int    `json:"outro_start"`
		OutroEnd   int    `json:"outro_end"`
	}

	episodes := []EpisodeDebug{}

	query := `
		SELECT id, title, intro_start, intro_end, outro_start, outro_end
		FROM medias
		WHERE type = 'episode'
		ORDER BY id DESC
		LIMIT 20
	`

	rows, err := database.DB.Query(query)
	if err != nil {
		log.Printf("DebugIntroOutro error: %v", err)
		http.Error(w, `{"error": "Database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var ep EpisodeDebug
		err := rows.Scan(&ep.ID, &ep.Title, &ep.IntroStart, &ep.IntroEnd, &ep.OutroStart, &ep.OutroEnd)
		if err != nil {
			log.Printf("DebugIntroOutro scan error: %v", err)
			continue
		}
		episodes = append(episodes, ep)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"count":    len(episodes),
		"episodes": episodes,
	})
}

// DetectShowIntroOutro triggers intro/outro detection for a specific show
func DetectShowIntroOutro(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	// Get show ID from URL parameter
	showIDStr := ps.ByName("id")
	showID, err := strconv.Atoi(showIDStr)
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}

	// Run detection
	results, err := indexer.DetectIntrosOutrosForShow(showID)
	if err != nil {
		log.Printf("DetectShowIntroOutro error: %v", err)
		http.Error(w, fmt.Sprintf(`{"error": "%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"show_id":  showID,
		"seasons":  results,
		"message": "Detection completed successfully",
	})
}

// Home returns the dashboard data for the home screen (GET /api/home)
func Home(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	// 1. Get "Continue Watching"
	continueWatching := []models.HomeMediaItem{}
	cwQuery := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       p.current_position_seconds, p.is_finished
		FROM progressions p
		JOIN medias m ON p.media_id = m.id
		WHERE p.user_id = ? AND p.is_finished = 0
		ORDER BY p.updated_at DESC
		LIMIT 10
	`
	rows, err := database.DB.Query(cwQuery, userID)
	if err != nil {
		log.Printf("Home error: failed to query continue watching: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var item models.HomeMediaItem
		var parentID sql.NullInt64
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		err := rows.Scan(
			&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
			&item.CurrentPositionSeconds, &item.IsFinished,
		)
		if err != nil {
			log.Printf("Home error: failed to scan continue watching row: %v", err)
			continue
		}

		if filePath.Valid {
			item.FilePath = filePath.String
		}
		if parentID.Valid {
			pid := int(parentID.Int64)
			item.ParentID = &pid
		}
		if posterURL.Valid {
			item.PosterURL = posterURL.String
		}
		if overview.Valid {
			item.Overview = overview.String
		}
		if releaseDate.Valid {
			item.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			item.TMDBID = int(tmdbID.Int64)
		}

		continueWatching = append(continueWatching, item)
	}

	// 2. Get "Recent Movies"
	recentMovies := []models.Media{}
	movieQuery := `
		SELECT id, type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias
		WHERE type = 'movie'
		ORDER BY created_at DESC
		LIMIT 15
	`
	mRows, err := database.DB.Query(movieQuery)
	if err != nil {
		log.Printf("Home error: failed to query recent movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer mRows.Close()

	for mRows.Next() {
		var m models.Media
		var parentID sql.NullInt64
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		err := mRows.Scan(
			&m.ID, &m.Type, &m.Title, &filePath, &m.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &m.CreatedAt,
		)
		if err != nil {
			log.Printf("Home error: failed to scan movie row: %v", err)
			continue
		}

		if filePath.Valid {
			m.FilePath = filePath.String
		}
		if parentID.Valid {
			pid := int(parentID.Int64)
			m.ParentID = &pid
		}
		if posterURL.Valid {
			m.PosterURL = posterURL.String
		}
		if overview.Valid {
			m.Overview = overview.String
		}
		if releaseDate.Valid {
			m.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			m.TMDBID = int(tmdbID.Int64)
		}

		recentMovies = append(recentMovies, m)
	}

	// 3. Get "Recent Shows" (TV Series)
	recentShows := []models.Media{}
	showQuery := `
		SELECT id, type, title, duration, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias
		WHERE type = 'show'
		ORDER BY created_at DESC
		LIMIT 15
	`
	sRows, err := database.DB.Query(showQuery)
	if err != nil {
		log.Printf("Home error: failed to query recent shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer sRows.Close()

	for sRows.Next() {
		var s models.Media
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		err := sRows.Scan(&s.ID, &s.Type, &s.Title, &s.Duration, &posterURL, &overview, &releaseDate, &tmdbID, &s.CreatedAt)
		if err != nil {
			log.Printf("Home error: failed to scan show row: %v", err)
			continue
		}

		if posterURL.Valid {
			s.PosterURL = posterURL.String
		}
		if overview.Valid {
			s.Overview = overview.String
		}
		if releaseDate.Valid {
			s.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			s.TMDBID = int(tmdbID.Int64)
		}

		recentShows = append(recentShows, s)
	}

	// Respond
	json.NewEncoder(w).Encode(models.HomeResponse{
		ContinueWatching: continueWatching,
		RecentMovies:     recentMovies,
		RecentShows:      recentShows,
	})
}

// ProgressRequest represents the payload sent by the Flutter client to report watch progression
type ProgressRequest struct {
	MediaID                int  `json:"media_id"`
	CurrentPositionSeconds int  `json:"current_position_seconds"`
	Duration               int  `json:"duration"` // client informs server of media duration (learned from player)
	IsFinished             bool `json:"is_finished"`
}

// UpdateProgress handles the streaming heartbeat and saves progress (POST /api/progress)
func UpdateProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req ProgressRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	if req.MediaID <= 0 {
		http.Error(w, `{"error": "Invalid media_id"}`, http.StatusBadRequest)
		return
	}

	// If client provided a duration, update it in the medias table
	if req.Duration > 0 {
		_, err := database.DB.Exec("UPDATE medias SET duration = ? WHERE id = ? AND (duration IS NULL OR duration = 0)", req.Duration, req.MediaID)
		if err != nil {
			log.Printf("Progress error: failed to update media duration: %v", err)
		}
	}

	// Determine if finished. If position is >= 90% of duration, mark as finished.
	isFinished := req.IsFinished
	if !isFinished && req.Duration > 0 && req.CurrentPositionSeconds > 0 {
		percentWatched := (float64(req.CurrentPositionSeconds) / float64(req.Duration)) * 100
		if percentWatched >= 90.0 {
			isFinished = true
		}
	}

	// Insert or replace progression
	query := `
		INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, media_id) DO UPDATE SET
			current_position_seconds = excluded.current_position_seconds,
			is_finished = excluded.is_finished,
			updated_at = CURRENT_TIMESTAMP
	`
	_, err := database.DB.Exec(query, userID, req.MediaID, req.CurrentPositionSeconds, isFinished)
	if err != nil {
		log.Printf("Progress error: failed to update progression: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "success",
		"is_finished": isFinished,
	})
}

// GetProgress returns the watch progression for a specific media ID (GET /api/progress?media_id=...)
func GetProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	mediaIDStr := r.URL.Query().Get("media_id")
	if mediaIDStr == "" {
		http.Error(w, `{"error": "media_id parameter is required"}`, http.StatusBadRequest)
		return
	}

	mediaID, err := strconv.Atoi(mediaIDStr)
	if err != nil {
		http.Error(w, `{"error": "invalid media_id"}`, http.StatusBadRequest)
		return
	}

	var currentPosition int
	var isFinished bool

	err = database.DB.QueryRow(
		"SELECT current_position_seconds, is_finished FROM progressions WHERE user_id = ? AND media_id = ?",
		userID, mediaID,
	).Scan(&currentPosition, &isFinished)

	if err != nil {
		if err == sql.ErrNoRows {
			// No progression exists yet
			json.NewEncoder(w).Encode(map[string]interface{}{
				"current_position_seconds": 0,
				"is_finished":              false,
			})
		} else {
			log.Printf("Progress error: failed to query: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"current_position_seconds": currentPosition,
		"is_finished":              isFinished,
	})
}

// GetMovies returns all indexed movies (GET /api/movies)
func GetMovies(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished
		FROM medias m
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'movie'
		ORDER BY m.title ASC
	`
	rows, err := database.DB.Query(query, userID)
	if err != nil {
		log.Printf("Movies error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.HomeMediaItem{}
	for rows.Next() {
		var item models.HomeMediaItem
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		err := rows.Scan(
			&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
			&item.CurrentPositionSeconds, &item.IsFinished,
		)
		if err != nil {
			log.Printf("Movies scan error: %v", err)
			continue
		}

		if filePath.Valid {
			item.FilePath = filePath.String
		}
		if posterURL.Valid {
			item.PosterURL = posterURL.String
		}
		if overview.Valid {
			item.Overview = overview.String
		}
		if releaseDate.Valid {
			item.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			item.TMDBID = int(tmdbID.Int64)
		}

		results = append(results, item)
	}

	json.NewEncoder(w).Encode(results)
}

// GetShows returns all indexed TV Shows (GET /api/shows)
func GetShows(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	rows, err := database.DB.Query("SELECT id, type, title, poster_url, overview, release_date, tmdb_id, imdb_id, created_at FROM medias WHERE type = 'show' ORDER BY title ASC")
	if err != nil {
		log.Printf("Shows error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.Media{}
	for rows.Next() {
		var s models.Media
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64
		var imdbID sql.NullString

		if err := rows.Scan(&s.ID, &s.Type, &s.Title, &posterURL, &overview, &releaseDate, &tmdbID, &imdbID, &s.CreatedAt); err != nil {
			log.Printf("Shows scan error: %v", err)
			continue
		}

		if posterURL.Valid {
			s.PosterURL = posterURL.String
		}
		if overview.Valid {
			s.Overview = overview.String
		}
		if releaseDate.Valid {
			s.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			s.TMDBID = int(tmdbID.Int64)
		}
		if imdbID.Valid {
			s.IMDbID = imdbID.String
		}

		results = append(results, s)
	}

	json.NewEncoder(w).Encode(results)
}

// GetShowSeasons returns all seasons for a TV Show (GET /api/shows/:id/seasons)
func GetShowSeasons(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	showID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}

	rows, err := database.DB.Query("SELECT id, type, title, parent_id, created_at FROM medias WHERE type = 'season' AND parent_id = ? ORDER BY title ASC", showID)
	if err != nil {
		log.Printf("Seasons error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.Media{}
	for rows.Next() {
		var m models.Media
		var parentID int

		if err := rows.Scan(&m.ID, &m.Type, &m.Title, &parentID, &m.CreatedAt); err != nil {
			log.Printf("Seasons scan error: %v", err)
			continue
		}
		m.ParentID = &parentID

		results = append(results, m)
	}

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

	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end
		FROM medias m
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		ORDER BY m.id ASC
	`
	rows, err := database.DB.Query(query, userID, seasonID)
	if err != nil {
		log.Printf("Episodes error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	results := []models.HomeMediaItem{}
	for rows.Next() {
		var item models.HomeMediaItem
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64
		var parentID int

		err := rows.Scan(
			&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
			&item.CurrentPositionSeconds, &item.IsFinished,
			&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		)
		if err != nil {
			log.Printf("Episodes scan error: %v", err)
			continue
		}

		item.ParentID = &parentID
		if filePath.Valid {
			item.FilePath = filePath.String
		}
		if posterURL.Valid {
			item.PosterURL = posterURL.String
		}
		if overview.Valid {
			item.Overview = overview.String
		}
		if releaseDate.Valid {
			item.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			item.TMDBID = int(tmdbID.Int64)
		}

		results = append(results, item)
	}

	json.NewEncoder(w).Encode(results)
}

// TriggerScan starts a new background media scan (POST /api/indexer/scan)
func TriggerScan(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	// In Docker, let's map media directories
	// We'll read these from environment variables with sensible defaults
	moviesDir := getEnv("MOVIES_DIR", "/media/Films")
	seriesDir := getEnv("SERIES_DIR", "/media/Series")

	if indexer.IsScanning {
		http.Error(w, `{"error": "Scan is already in progress"}`, http.StatusConflict)
		return
	}

	indexer.ScanMedia(moviesDir, seriesDir)

	w.Write([]byte(`{"status": "success", "message": "Scan triggered in background"}`))
}

// GetScanStatus returns the current status of the indexer (GET /api/indexer/status)
func GetScanStatus(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"is_scanning": indexer.IsScanning,
	})
}

// GetNextEpisode returns the next episode in the same season (GET /api/episodes/:id/next)
func GetNextEpisode(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	// Get current episode's parent_id (season)
	var seasonID int
	err = database.DB.QueryRow("SELECT parent_id FROM medias WHERE id = ? AND type = 'episode'", episodeID).Scan(&seasonID)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("NextEpisode error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	// Find the next episode (next higher ID in same season)
	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end
		FROM medias m
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ? AND m.id > ?
		ORDER BY m.id ASC
		LIMIT 1
	`
	var item models.HomeMediaItem
	var filePath sql.NullString
	var posterURL sql.NullString
	var overview sql.NullString
	var releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var parentID int

	err = database.DB.QueryRow(query, userID, seasonID, episodeID).Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &item.IsFinished,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			json.NewEncoder(w).Encode(map[string]interface{}{"has_next": false})
			return
		}
		log.Printf("NextEpisode error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	item.ParentID = &parentID
	if filePath.Valid {
		item.FilePath = filePath.String
	}
	if posterURL.Valid {
		item.PosterURL = posterURL.String
	}
	if overview.Valid {
		item.Overview = overview.String
	}
	if releaseDate.Valid {
		item.ReleaseDate = releaseDate.String
	}
	if tmdbID.Valid {
		item.TMDBID = int(tmdbID.Int64)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"has_next": true,
		"episode":  item,
	})
}

// GetEpisodeTimestamps returns the intro/outro timestamps for an episode (GET /api/episodes/:id/timestamps)
func GetEpisodeTimestamps(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	var introStart, introEnd, outroStart, outroEnd, seasonID int
	err = database.DB.QueryRow(
		"SELECT intro_start, intro_end, outro_start, outro_end, parent_id FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&introStart, &introEnd, &outroStart, &outroEnd, &seasonID)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("Timestamps error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	// If timestamps are empty, trigger background detection
	if introEnd == 0 && outroStart == 0 && seasonID > 0 {
		go func(sID int) {
			log.Printf("Timestamps: Triggering background detection for season %d (episode %d)", sID, episodeID)
			if err := indexer.AnalyzeSeason(sID); err != nil {
				log.Printf("Timestamps: Background detection failed for season %d: %v", sID, err)
			}
		}(seasonID)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"media_id": episodeID,
		"intro": map[string]interface{}{
			"start": introStart,
			"end":   introEnd,
		},
		"outro": map[string]interface{}{
			"start": outroStart,
			"end":   outroEnd,
		},
	})
}

// GetEpisodeChapters returns chapters dynamically parsed using ffprobe (GET /api/episodes/:id/chapters)
func GetEpisodeChapters(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	// Fetch file path of the episode
	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ? AND type = 'episode'", episodeID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("GetEpisodeChapters DB error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	if filePath == "" {
		http.Error(w, `{"error": "Media file path is empty"}`, http.StatusBadRequest)
		return
	}

	// Spawn ffprobe
	cmd := exec.Command("ffprobe", "-v", "quiet", "-print_format", "json", "-show_chapters", filePath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err = cmd.Run()
	if err != nil {
		log.Printf("ffprobe execution failed: %v, stderr: %s", err, stderr.String())
		// Return empty list instead of 500 so client doesn't crash
		json.NewEncoder(w).Encode(map[string]interface{}{"chapters": []interface{}{}})
		return
	}

	// Parse JSON output
	var ffResponse struct {
		Chapters []struct {
			ID        int                    `json:"id"`
			StartTime string                 `json:"start_time"`
			EndTime   string                 `json:"end_time"`
			Tags      map[string]interface{} `json:"tags"`
		} `json:"chapters"`
	}

	if err := json.Unmarshal(stdout.Bytes(), &ffResponse); err != nil {
		log.Printf("Failed to unmarshal ffprobe output: %v", err)
		json.NewEncoder(w).Encode(map[string]interface{}{"chapters": []interface{}{}})
		return
	}

	// Map to simplified schema compatible with client structure
	type ChapterItem struct {
		ID        int     `json:"id"`
		StartTime float64 `json:"start_time"`
		EndTime   float64 `json:"end_time"`
		Title     string  `json:"title"`
	}

	chapters := make([]ChapterItem, 0)
	for _, c := range ffResponse.Chapters {
		start, _ := strconv.ParseFloat(c.StartTime, 64)
		end, _ := strconv.ParseFloat(c.EndTime, 64)
		
		title := fmt.Sprintf("Chapter %d", c.ID)
		if c.Tags != nil {
			if t, ok := c.Tags["title"]; ok {
				title = fmt.Sprintf("%v", t)
			} else if t, ok := c.Tags["TITLE"]; ok {
				title = fmt.Sprintf("%v", t)
			}
		}

		chapters = append(chapters, ChapterItem{
			ID:        c.ID,
			StartTime: start,
			EndTime:   end,
			Title:     title,
		})
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"chapters": chapters,
	})
}

// Helper to get environment variables with default values
func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}
