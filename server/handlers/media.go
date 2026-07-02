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
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"
	"project-player/server/streaming"
	"project-player/server/subtitles"

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
		"show_id": showID,
		"seasons": results,
		"message": "Detection completed successfully",
	})
}

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
	recentMovies := []models.Media{}
	movieQuery := `
		SELECT id, type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias
		WHERE type = 'movie'
		ORDER BY created_at DESC
		LIMIT 15
	`
	recentMovieRows, err := database.DB.Query(movieQuery)
	if err != nil {
		log.Printf("Home error: failed to query recent movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	defer recentMovieRows.Close()

	for recentMovieRows.Next() {
		var m models.Media
		var parentID sql.NullInt64
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		err := recentMovieRows.Scan(
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

	discoveryMovies, err := queryRandomMovies(40)
	if err != nil {
		log.Printf("Home error: failed to query discovery movies: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	discoveryShows, err := queryRandomShows(40)
	if err != nil {
		log.Printf("Home error: failed to query discovery shows: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	// Respond
	json.NewEncoder(w).Encode(models.HomeResponse{
		ContinueWatching: continueWatching,
		RecentMovies:     recentMovies,
		RecentShows:      recentShows,
		DiscoveryMovies:  discoveryMovies,
		DiscoveryShows:   discoveryShows,
	})
}

func queryRandomMovies(limit int) ([]models.Media, error) {
	rows, err := database.DB.Query(`
		SELECT id, type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias
		WHERE type = 'movie'
		  AND COALESCE(poster_url, '') != ''
		ORDER BY RANDOM()
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []models.Media
	for rows.Next() {
		var m models.Media
		var parentID sql.NullInt64
		var filePath sql.NullString
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		if err := rows.Scan(
			&m.ID, &m.Type, &m.Title, &filePath, &m.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &m.CreatedAt,
		); err != nil {
			log.Printf("Discovery movies scan error: %v", err)
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

		results = append(results, m)
	}
	return results, nil
}

func queryRandomShows(limit int) ([]models.Media, error) {
	rows, err := database.DB.Query(`
		SELECT id, type, title, duration, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias
		WHERE type = 'show'
		  AND COALESCE(poster_url, '') != ''
		ORDER BY RANDOM()
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []models.Media
	for rows.Next() {
		var s models.Media
		var posterURL sql.NullString
		var overview sql.NullString
		var releaseDate sql.NullString
		var tmdbID sql.NullInt64

		if err := rows.Scan(&s.ID, &s.Type, &s.Title, &s.Duration, &posterURL, &overview, &releaseDate, &tmdbID, &s.CreatedAt); err != nil {
			log.Printf("Discovery shows scan error: %v", err)
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

		results = append(results, s)
	}
	return results, nil
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
	effectiveDuration := req.Duration
	if req.Duration > 0 {
		_, err := database.DB.Exec("UPDATE medias SET duration = ? WHERE id = ? AND (duration IS NULL OR duration = 0)", req.Duration, req.MediaID)
		if err != nil {
			log.Printf("Progress error: failed to update media duration: %v", err)
		}
	} else {
		_ = database.DB.QueryRow(
			"SELECT COALESCE(duration, 0) FROM medias WHERE id = ?",
			req.MediaID,
		).Scan(&effectiveDuration)
	}

	// Determine if finished. If position is >= 90% of duration, mark as finished.
	isFinished := req.IsFinished
	if !isFinished && effectiveDuration > 0 && req.CurrentPositionSeconds > 0 {
		percentWatched := (float64(req.CurrentPositionSeconds) / float64(effectiveDuration)) * 100
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

type watchedRequest struct {
	Watched bool `json:"watched"`
}

// SetMediaWatched marks or unmarks a movie/episode as watched (POST /api/media/:id/watched).
func SetMediaWatched(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	var req watchedRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	var mediaType string
	var duration int
	err = database.DB.QueryRow(
		"SELECT type, COALESCE(duration, 0) FROM medias WHERE id = ?",
		mediaID,
	).Scan(&mediaType, &duration)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("Watched error: failed to load media %d: %v", mediaID, err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	if mediaType != string(models.TypeMovie) && mediaType != string(models.TypeEpisode) {
		http.Error(w, `{"error": "Only movies and episodes can be marked as watched"}`, http.StatusBadRequest)
		return
	}

	position := 0
	if req.Watched {
		_ = database.DB.QueryRow(
			"SELECT COALESCE(current_position_seconds, 0) FROM progressions WHERE user_id = ? AND media_id = ?",
			userID, mediaID,
		).Scan(&position)
		if duration > 0 {
			position = duration
		} else if position <= 0 {
			position = 1
		}

		_, err = database.DB.Exec(`
			INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
			VALUES (?, ?, ?, 1, CURRENT_TIMESTAMP)
			ON CONFLICT(user_id, media_id) DO UPDATE SET
				current_position_seconds = excluded.current_position_seconds,
				is_finished = 1,
				updated_at = CURRENT_TIMESTAMP
		`, userID, mediaID, position)
		if err != nil {
			log.Printf("Watched error: failed to update media %d: %v", mediaID, err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
			return
		}
	} else {
		result, updateErr := database.DB.Exec(`
			UPDATE progressions
			SET is_finished = 0, updated_at = CURRENT_TIMESTAMP
			WHERE user_id = ? AND media_id = ?
		`, userID, mediaID)
		if updateErr != nil {
			log.Printf("Watched error: failed to update media %d: %v", mediaID, updateErr)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
			return
		}
		if rows, _ := result.RowsAffected(); rows == 0 {
			json.NewEncoder(w).Encode(map[string]interface{}{
				"status":                   "success",
				"is_finished":              false,
				"current_position_seconds": 0,
			})
			return
		}
		_ = database.DB.QueryRow(
			"SELECT COALESCE(current_position_seconds, 0) FROM progressions WHERE user_id = ? AND media_id = ?",
			userID, mediaID,
		).Scan(&position)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":                   "success",
		"is_finished":              req.Watched,
		"current_position_seconds": position,
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

	indexer.RefreshSeasonEpisodesFromTMDB(seasonID)

	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id,
		       COALESCE(NULLIF(m.poster_url, ''), show_m.poster_url, '') AS poster_url,
		       m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(NULLIF(m.season_number, 0), season.season_number, 0),
		       COALESCE(m.episode_number, 0),
		       COALESCE(season.title, ''),
		       COALESCE(show_m.title, ''),
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end
		FROM medias m
		LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		ORDER BY COALESCE(NULLIF(m.episode_number, 0), 9999), m.id ASC
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
		var seasonNumber, episodeNumber int
		var seasonTitle string
		var showTitle sql.NullString

		err := rows.Scan(
			&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
			&seasonNumber, &episodeNumber, &seasonTitle, &showTitle,
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
		item.SeasonNumber = resolveSeasonNumber(seasonTitle, item.FilePath, seasonNumber)
		item.EpisodeNumber = parseEpisodeNumber(item.Title, episodeNumber)
		if showTitle.Valid && showTitle.String != "" {
			item.ShowTitle = showTitle.String
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

// TriggerShowDedupe merges duplicate TV show and movie rows (POST /api/indexer/dedupe).
func TriggerShowDedupe(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	go func() {
		indexer.DedupeDuplicateShows()
		indexer.DedupeDuplicateMovies()
	}()
	w.Write([]byte(`{"status": "success", "message": "Deduplication started in background"}`))
}

// TriggerMetadataBackfill fetches missing TMDB posters without re-scanning files.
func TriggerMetadataBackfill(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	if indexer.IsBackfilling {
		http.Error(w, `{"error": "Metadata backfill is already in progress"}`, http.StatusConflict)
		return
	}

	indexer.BackfillMissingMetadataAsync()
	w.Write([]byte(`{"status": "success", "message": "Metadata backfill started in background"}`))
}

// EnrichMediaMetadata fetches TMDB data for one movie/show (POST /api/media/:id/metadata/enrich).
func EnrichMediaMetadata(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	if !indexer.EnrichMediaByID(mediaID) {
		http.Error(w, `{"error": "No metadata found on TMDB"}`, http.StatusNotFound)
		return
	}

	var m models.Media
	var filePath, posterURL, overview, releaseDate sql.NullString
	var parentID sql.NullInt64
	var tmdbID sql.NullInt64
	err = database.DB.QueryRow(`
		SELECT id, type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias WHERE id = ?`, mediaID,
	).Scan(&m.ID, &m.Type, &m.Title, &filePath, &m.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &m.CreatedAt)
	if err != nil {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
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

	json.NewEncoder(w).Encode(m)
}

// GetMediaDetails returns rich, Emby-style catalog details for a movie/show
// (GET /api/media/:id/details). Local library data (id, title, poster, overview,
// release date) is merged with live TMDB metadata (cast, genres, rating,
// backdrop, crew). Degrades gracefully to local-only when TMDB is unavailable.
func GetMediaDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	var mediaType string
	var title string
	var filePath, posterURL, overview, releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var duration int
	err = database.DB.QueryRow(`
		SELECT type, title, file_path, COALESCE(duration, 0), poster_url, overview, release_date, tmdb_id
		FROM medias WHERE id = ? AND type IN ('movie', 'show')`, mediaID,
	).Scan(&mediaType, &title, &filePath, &duration, &posterURL, &overview, &releaseDate, &tmdbID)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("MediaDetails error: failed to load media %d: %v", mediaID, err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	mt := models.MediaType(mediaType)

	// Make sure we have a TMDB id to query the live catalog. Enrich on the fly
	// when missing (e.g. freshly indexed titles).
	if !tmdbID.Valid || tmdbID.Int64 <= 0 {
		if indexer.EnrichMediaByID(mediaID) {
			var refreshed sql.NullInt64
			_ = database.DB.QueryRow("SELECT tmdb_id FROM medias WHERE id = ?", mediaID).Scan(&refreshed)
			tmdbID = refreshed
		}
	}

	// Base payload from the local record — always returned even if TMDB fails.
	details := models.MediaDetails{
		ID:          mediaID,
		Type:        mt,
		Title:       title,
		Duration:    duration,
		Overview:    overview.String,
		PosterURL:   posterURL.String,
		ReleaseDate: releaseDate.String,
	}
	if filePath.Valid && filePath.String != "" {
		details.FileName = filepath.Base(filePath.String)
	}
	if tmdbID.Valid {
		details.TMDBID = int(tmdbID.Int64)
	}

	if catalog := indexer.FetchMediaCatalogDetails(details.TMDBID, mt); catalog != nil {
		mergeCatalogDetails(&details, catalog)
	}

	json.NewEncoder(w).Encode(details)
}

// mergeCatalogDetails overlays live TMDB catalog data onto the local record,
// keeping the local id/poster while filling in the rich fields.
func mergeCatalogDetails(dst *models.MediaDetails, src *models.MediaDetails) {
	if src.Title != "" {
		dst.Title = src.Title
	}
	dst.OriginalTitle = src.OriginalTitle
	dst.Tagline = src.Tagline
	if src.Overview != "" {
		dst.Overview = src.Overview
	}
	if src.PosterURL != "" && dst.PosterURL == "" {
		dst.PosterURL = src.PosterURL
	}
	dst.BackdropURL = src.BackdropURL
	dst.LogoURL = src.LogoURL
	if src.ReleaseDate != "" {
		dst.ReleaseDate = src.ReleaseDate
	}
	if src.Runtime > 0 {
		dst.Runtime = src.Runtime
	}
	dst.Status = src.Status
	dst.VoteAverage = src.VoteAverage
	dst.Genres = src.Genres
	dst.Studios = src.Studios
	dst.Countries = src.Countries
	dst.OriginalLang = src.OriginalLang
	dst.Director = src.Director
	dst.Writers = src.Writers
	dst.Cast = src.Cast
	dst.Collection = src.Collection
	dst.NumberOfSeasons = src.NumberOfSeasons
	dst.NumberOfEpisodes = src.NumberOfEpisodes
}

// GetPersonDetails returns an actor/crew profile with filmography
// (GET /api/person/:id). The :id is a TMDB person id. Filmography entries are
// tagged with their local library id when the title is owned.
func GetPersonDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	personID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || personID <= 0 {
		http.Error(w, `{"error": "Invalid person ID"}`, http.StatusBadRequest)
		return
	}

	person := indexer.FetchPersonDetails(personID)
	if person == nil {
		http.Error(w, `{"error": "Person not found"}`, http.StatusNotFound)
		return
	}

	attachLocalIDs(person.Filmography)
	json.NewEncoder(w).Encode(person)
}

// GetCollectionDetails returns a movie saga with its ordered parts
// (GET /api/collection/:id). The :id is a TMDB collection id.
func GetCollectionDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	collectionID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || collectionID <= 0 {
		http.Error(w, `{"error": "Invalid collection ID"}`, http.StatusBadRequest)
		return
	}

	collection := indexer.FetchCollectionDetails(collectionID)
	if collection == nil {
		http.Error(w, `{"error": "Collection not found"}`, http.StatusNotFound)
		return
	}

	attachLocalIDs(collection.Parts)
	json.NewEncoder(w).Encode(collection)
}

// attachLocalIDs fills in the LocalID of catalog items that exist in the
// library, matched by TMDB id + type. Items not owned keep LocalID == 0.
func attachLocalIDs(items []models.CatalogItem) {
	if len(items) == 0 {
		return
	}

	// Collect the TMDB ids to resolve in a single query.
	tmdbIDs := make([]interface{}, 0, len(items))
	seen := map[int]bool{}
	for _, it := range items {
		if it.TMDBID > 0 && !seen[it.TMDBID] {
			seen[it.TMDBID] = true
			tmdbIDs = append(tmdbIDs, it.TMDBID)
		}
	}
	if len(tmdbIDs) == 0 {
		return
	}

	placeholders := strings.TrimRight(strings.Repeat("?,", len(tmdbIDs)), ",")
	query := fmt.Sprintf(
		"SELECT id, type, tmdb_id FROM medias WHERE type IN ('movie','show') AND tmdb_id IN (%s)",
		placeholders,
	)
	rows, err := database.DB.Query(query, tmdbIDs...)
	if err != nil {
		log.Printf("attachLocalIDs query error: %v", err)
		return
	}
	defer rows.Close()

	// map[tmdbID]map[mediaType]localID
	owned := map[int]map[string]int{}
	for rows.Next() {
		var id, tmdbID int
		var mediaType string
		if err := rows.Scan(&id, &mediaType, &tmdbID); err != nil {
			continue
		}
		if owned[tmdbID] == nil {
			owned[tmdbID] = map[string]int{}
		}
		owned[tmdbID][mediaType] = id
	}

	for i := range items {
		if byType, ok := owned[items[i].TMDBID]; ok {
			if localID, ok := byType[items[i].MediaType]; ok {
				items[i].LocalID = localID
			}
		}
	}
}

// SearchTMDBMetadata returns TMDB candidates for a manual query
// (GET /api/tmdb/search?query=...&type=movie|show), used by the poster picker.
func SearchTMDBMetadata(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	query := strings.TrimSpace(r.URL.Query().Get("query"))
	if query == "" {
		http.Error(w, `{"error": "query is required"}`, http.StatusBadRequest)
		return
	}

	mediaType := models.TypeMovie
	if t := r.URL.Query().Get("type"); t == "show" || t == "tv" {
		mediaType = models.TypeShow
	}

	results := indexer.SearchTMDBCandidates(query, mediaType)
	if results == nil {
		results = []models.TMDBSearchCandidate{}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"results": results})
}

// RematchMediaMetadata re-identifies a movie/show against TMDB, letting the user
// fix a wrong match (POST /api/media/:id/metadata/rematch?title=...&tmdb_id=...).
func RematchMediaMetadata(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	overrideTitle := strings.TrimSpace(r.URL.Query().Get("title"))
	overrideTMDBID := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("tmdb_id")); raw != "" {
		if v, convErr := strconv.Atoi(raw); convErr == nil {
			overrideTMDBID = v
		}
	}

	if !indexer.RematchMediaByID(mediaID, overrideTitle, overrideTMDBID) {
		http.Error(w, `{"error": "No matching title found on TMDB"}`, http.StatusNotFound)
		return
	}

	var m models.Media
	var filePath, posterURL, overview, releaseDate sql.NullString
	var parentID, tmdbID sql.NullInt64
	err = database.DB.QueryRow(`
		SELECT id, type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, created_at
		FROM medias WHERE id = ?`, mediaID,
	).Scan(&m.ID, &m.Type, &m.Title, &filePath, &m.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &m.CreatedAt)
	if err != nil {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
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

	json.NewEncoder(w).Encode(m)
}

// GetScanStatus returns the current status of the indexer (GET /api/indexer/status)
func GetScanStatus(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"is_scanning":             indexer.IsScanning,
		"is_backfilling_metadata": indexer.IsBackfilling,
		"is_extracting_subtitles": subtitles.IsExtracting,
		"subtitle_extraction":     subtitles.LastExtractStats(),
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

	// Get current episode's season and episode number
	var seasonID, currentEpisodeNum int
	err = database.DB.QueryRow(
		"SELECT parent_id, COALESCE(episode_number, 0) FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&seasonID, &currentEpisodeNum)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("NextEpisode error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	// Find the next episode in the same season
	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end,
		       COALESCE(NULLIF(m.season_number, 0), season.season_number, 0),
		       COALESCE(m.episode_number, 0),
		       COALESCE(season.title, ''),
		       COALESCE(show_m.title, '')
		FROM medias m
		LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		  AND COALESCE(m.episode_number, 0) > ?
		ORDER BY COALESCE(NULLIF(m.episode_number, 0), 9999), m.id ASC
		LIMIT 1
	`
	var item models.HomeMediaItem
	var filePath sql.NullString
	var posterURL sql.NullString
	var overview sql.NullString
	var releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var parentID int
	var seasonNumber, episodeNumber int
	var seasonTitle string
	var showTitle sql.NullString

	err = database.DB.QueryRow(query, userID, seasonID, currentEpisodeNum).Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &item.IsFinished,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&seasonNumber, &episodeNumber, &seasonTitle, &showTitle,
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
	item.SeasonNumber = resolveSeasonNumber(seasonTitle, item.FilePath, seasonNumber)
	item.EpisodeNumber = parseEpisodeNumber(item.Title, episodeNumber)
	if showTitle.Valid && showTitle.String != "" {
		item.ShowTitle = showTitle.String
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

	var introStart, introEnd, outroStart, outroEnd, seasonID, duration int
	err = database.DB.QueryRow(
		"SELECT intro_start, intro_end, outro_start, outro_end, parent_id, COALESCE(duration, 0) FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&introStart, &introEnd, &outroStart, &outroEnd, &seasonID, &duration)
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

	// Drop corrupt intro markers (e.g. a false-positive chapter spanning to EOF).
	if !indexer.IsPlausibleIntroRange(introStart, introEnd, duration) {
		introStart, introEnd = 0, 0
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"media_id":    episodeID,
		"intro_start": introStart,
		"intro_end":   introEnd,
		"outro_start": outroStart,
		"outro_end":   outroEnd,
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

// GetMediaTracks returns the audio and subtitle tracks of a media file as
// detected by ffprobe. This lets the client display consistent track names
// in both direct play and transcoding modes.
func GetMediaTracks(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ?", mediaID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		} else {
			log.Printf("GetMediaTracks DB error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	if filePath == "" {
		http.Error(w, `{"error": "Media file path is empty"}`, http.StatusBadRequest)
		return
	}

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		http.Error(w, `{"error": "Media file not found on disk"}`, http.StatusNotFound)
		return
	}

	probe, err := streaming.ProbeTracks(filePath)
	if err != nil {
		log.Printf("GetMediaTracks probe error for media %d: %v", mediaID, err)
		http.Error(w, `{"error": "Failed to probe media tracks"}`, http.StatusInternalServerError)
		return
	}

	// Audio comes from the file (ffprobe). Subtitles merge ffprobe discovery
	// (always visible in the UI) with DB registration (ready=true when extracted).
	// Extraction itself stays async — this endpoint must remain fast.
	subs := []interface{}{}
	for _, t := range subtitles.Catalog(mediaID, probe) {
		subs = append(subs, t)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"audio":     probe.Audio,
		"subtitles": subs,
	})
}

// Helper to get environment variables with default values
func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}
