package handlers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)
// resolveShowFromEpisode returns show id/title/poster for an episode row.
// Handles the normal Show → Season → Episode tree and a direct Episode → Show link.
func resolveShowFromEpisode(episodeID, episodeParentID int) (showID int, showTitle, showPoster string, ok bool) {
	_ = episodeID
	// Standard: episode.parent_id → season → show
	err := database.DB.QueryRow(`
		SELECT show_m.id, show_m.title, COALESCE(show_m.poster_url, '')
		FROM medias season
		JOIN medias show_m ON show_m.id = season.parent_id AND show_m.type = 'show'
		WHERE season.id = ? AND season.type = 'season'
		LIMIT 1`, episodeParentID,
	).Scan(&showID, &showTitle, &showPoster)
	if err == nil && showID > 0 {
		return showID, showTitle, showPoster, true
	}

	// Fallback: episode linked directly to a show (legacy / bad index data).
	err = database.DB.QueryRow(`
		SELECT id, title, COALESCE(poster_url, '')
		FROM medias
		WHERE id = ? AND type = 'show'
		LIMIT 1`, episodeParentID,
	).Scan(&showID, &showTitle, &showPoster)
	if err == nil && showID > 0 {
		return showID, showTitle, showPoster, true
	}

	return 0, "", "", false
}

func scanContinueWatchingMovieRow(rows *sql.Rows) (models.HomeMediaItem, time.Time, error) {
	var item models.HomeMediaItem
	var parentID sql.NullInt64
	var filePath, posterURL, overview, releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var updatedAt time.Time
	var isFinishedInt int

	err := rows.Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL,
		&overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &isFinishedInt,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&updatedAt,
	)
	if err != nil {
		return item, time.Time{}, err
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
	item.IsFinished = isFinishedInt != 0
	item.UpdatedAt = updatedAt
	return item, updatedAt, nil
}

func buildMovieContinueWatching(userID int, hidden map[string]struct{}) ([]models.HomeMediaItem, error) {
	rows, err := database.DB.Query(`
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url,
		       m.overview, m.release_date, m.tmdb_id, m.created_at,
		       p.current_position_seconds, p.is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end,
		       p.updated_at
		FROM progressions p
		JOIN medias m ON p.media_id = m.id AND m.type = 'movie'
		WHERE p.user_id = ?
		  AND IFNULL(p.is_finished, 0) = 0
		  AND p.current_position_seconds > 0
		ORDER BY p.updated_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []models.HomeMediaItem
	for rows.Next() {
		item, _, err := scanContinueWatchingMovieRow(rows)
		if err != nil {
			log.Printf("ContinueWatching: movie scan error: %v", err)
			continue
		}
		if !meetsContinueWatchingThreshold(item.CurrentPositionSeconds, item.Duration) {
			continue
		}
		if isContinueWatchingHidden(hidden, item.ID, 0) {
			continue
		}
		items = append(items, item)
	}
	return items, nil
}

type showProgressActivity struct {
	showID    int
	updatedAt time.Time
}

const minContinueWatchingProgressPercent = 10.0

func meetsContinueWatchingThreshold(positionSeconds, durationSeconds int) bool {
	if positionSeconds <= 0 {
		return false
	}
	if durationSeconds <= 0 {
		return true
	}
	percent := (float64(positionSeconds) / float64(durationSeconds)) * 100
	return percent >= minContinueWatchingProgressPercent
}

// listShowsWithProgress returns show IDs where the user has any episode progression,
// ordered by most recent activity (including finished episodes).
func listShowsWithProgress(userID int) ([]showProgressActivity, error) {
	rows, err := database.DB.Query(`
		SELECT COALESCE(show_s.id, show_d.id) AS show_id,
		       MAX(p.updated_at) AS last_activity
		FROM progressions p
		JOIN medias ep ON p.media_id = ep.id AND ep.type = 'episode'
		LEFT JOIN medias season ON season.id = ep.parent_id AND season.type = 'season'
		LEFT JOIN medias show_s ON show_s.id = season.parent_id AND show_s.type = 'show'
		LEFT JOIN medias show_d ON show_d.id = ep.parent_id AND show_d.type = 'show'
		WHERE p.user_id = ?
		  AND COALESCE(show_s.id, show_d.id) IS NOT NULL
		GROUP BY show_id
		ORDER BY last_activity DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []showProgressActivity
	for rows.Next() {
		var act showProgressActivity
		var updatedAtRaw sql.NullString
		if err := rows.Scan(&act.showID, &updatedAtRaw); err != nil {
			log.Printf("ContinueWatching: show activity scan error: %v", err)
			continue
		}
		if act.showID <= 0 {
			continue
		}
		act.updatedAt = scanSQLiteTime(updatedAtRaw)
		out = append(out, act)
	}
	return out, nil
}

func loadShowMetadata(showID int) (title, poster string, err error) {
	err = database.DB.QueryRow(`
		SELECT title, COALESCE(poster_url, '')
		FROM medias
		WHERE id = ? AND type = 'show'
		LIMIT 1`, showID,
	).Scan(&title, &poster)
	return title, poster, err
}

func episodeRowToContinueWatchingItem(showID int, showTitle, showPoster string, row *episodeProgressRow, updatedAt time.Time) models.HomeMediaItem {
	item := row.item
	item.SeasonNumber = row.seasonNumber
	item.EpisodeNumber = row.episodeNumber
	item.ShowID = showID
	item.ShowTitle = showTitle
	item.ShowPosterURL = showPoster
	item.EpisodeTitle = item.Title
	item.CurrentPositionSeconds = row.item.CurrentPositionSeconds
	item.IsFinished = row.item.IsFinished
	item.UpdatedAt = updatedAt
	return item
}

func hasFinishedShowEpisode(episodes []episodeProgressRow) bool {
	for _, ep := range episodes {
		if ep.isFinished {
			return true
		}
	}
	return false
}

func meetsShowContinueWatchingThreshold(row *episodeProgressRow, episodes []episodeProgressRow) bool {
	if row == nil {
		return false
	}
	// Once at least one episode is finished, we keep surfacing the show with the
	// next resume target even if that next episode is still at position 0.
	if hasFinishedShowEpisode(episodes) {
		return true
	}
	return meetsContinueWatchingThreshold(row.currentPosition, row.item.Duration)
}

func buildShowContinueWatching(userID int, hidden map[string]struct{}) ([]models.HomeMediaItem, error) {
	activities, err := listShowsWithProgress(userID)
	if err != nil {
		return nil, err
	}

	var items []models.HomeMediaItem
	for _, act := range activities {
		episodes, err := loadShowEpisodesWithProgress(act.showID, userID)
		if err != nil {
			log.Printf("ContinueWatching: load episodes for show %d: %v", act.showID, err)
			continue
		}
		row, ok := findResumeEpisodeRow(episodes)
		if !ok || row == nil {
			continue
		}
		if !meetsShowContinueWatchingThreshold(row, episodes) {
			continue
		}
		if isContinueWatchingHidden(hidden, 0, act.showID) {
			continue
		}
		showTitle, showPoster, err := loadShowMetadata(act.showID)
		if err != nil {
			log.Printf("ContinueWatching: show metadata %d: %v", act.showID, err)
			continue
		}
		items = append(items, episodeRowToContinueWatchingItem(act.showID, showTitle, showPoster, row, act.updatedAt))
	}

	log.Printf("ContinueWatching: %d in-progress show(s) for user %d", len(items), userID)
	return items, nil
}

func buildContinueWatching(userID int, limit int) ([]models.HomeMediaItem, error) {
	hidden, err := loadHiddenContinueWatchingKeys(userID)
	if err != nil {
		log.Printf("ContinueWatching: hidden keys query failed for user %d: %v", userID, err)
		hidden = map[string]struct{}{}
	}

	movies, err := buildMovieContinueWatching(userID, hidden)
	if err != nil {
		return nil, err
	}

	shows, err := buildShowContinueWatching(userID, hidden)
	if err != nil {
		log.Printf("ContinueWatching: show query failed for user %d: %v", userID, err)
		shows = nil
	}

	combined := append(movies, shows...)
	sort.Slice(combined, func(i, j int) bool {
		return combined[i].UpdatedAt.After(combined[j].UpdatedAt)
	})

	if limit > 0 && len(combined) > limit {
		combined = combined[:limit]
	}
	return combined, nil
}

func continueWatchingMovieKey(movieID int) string {
	return fmt.Sprintf("movie:%d", movieID)
}

func continueWatchingShowKey(showID int) string {
	return fmt.Sprintf("show:%d", showID)
}

func isContinueWatchingHidden(hidden map[string]struct{}, movieID, showID int) bool {
	if hidden == nil {
		return false
	}
	if showID > 0 {
		_, ok := hidden[continueWatchingShowKey(showID)]
		return ok
	}
	if movieID > 0 {
		_, ok := hidden[continueWatchingMovieKey(movieID)]
		return ok
	}
	return false
}

func loadHiddenContinueWatchingKeys(userID int) (map[string]struct{}, error) {
	rows, err := database.DB.Query(
		`SELECT entry_key FROM continue_watching_hidden WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make(map[string]struct{})
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			continue
		}
		if key != "" {
			out[key] = struct{}{}
		}
	}
	return out, nil
}

func hideContinueWatchingEntry(userID int, entryKey string) error {
	_, err := database.DB.Exec(`
		INSERT INTO continue_watching_hidden (user_id, entry_key, hidden_at)
		VALUES (?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, entry_key) DO UPDATE SET hidden_at = CURRENT_TIMESTAMP
	`, userID, entryKey)
	return err
}

func resolveShowIDForEpisode(episodeID int) (int, bool) {
	var parentID int
	err := database.DB.QueryRow(
		`SELECT parent_id FROM medias WHERE id = ? AND type = 'episode' LIMIT 1`,
		episodeID,
	).Scan(&parentID)
	if err != nil {
		return 0, false
	}
	showID, _, _, ok := resolveShowFromEpisode(episodeID, parentID)
	return showID, ok && showID > 0
}

// UnhideContinueWatchingOnProgress removes a hidden entry when the user watches
// again so the home row can repopulate naturally.
func UnhideContinueWatchingOnProgress(userID, mediaID int, mediaType string, positionSeconds int) {
	if positionSeconds <= 0 {
		return
	}

	var entryKey string
	switch mediaType {
	case string(models.TypeMovie):
		entryKey = continueWatchingMovieKey(mediaID)
	case string(models.TypeEpisode):
		showID, ok := resolveShowIDForEpisode(mediaID)
		if !ok {
			return
		}
		entryKey = continueWatchingShowKey(showID)
	default:
		return
	}

	_, _ = database.DB.Exec(
		`DELETE FROM continue_watching_hidden WHERE user_id = ? AND entry_key = ?`,
		userID, entryKey,
	)
}

type hideContinueWatchingRequest struct {
	MovieID *int `json:"movie_id"`
	ShowID  *int `json:"show_id"`
}

// HideFromContinueWatching hides an item from the home row without deleting progress.
func HideFromContinueWatching(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req hideContinueWatchingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	var entryKey string
	if req.ShowID != nil && *req.ShowID > 0 {
		entryKey = continueWatchingShowKey(*req.ShowID)
	} else if req.MovieID != nil && *req.MovieID > 0 {
		entryKey = continueWatchingMovieKey(*req.MovieID)
	} else {
		http.Error(w, `{"error": "movie_id or show_id is required"}`, http.StatusBadRequest)
		return
	}

	if err := hideContinueWatchingEntry(userID, entryKey); err != nil {
		log.Printf("ContinueWatching: hide failed for user %d key %s: %v", userID, entryKey, err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "success",
	})
}
