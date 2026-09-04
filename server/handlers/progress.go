package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// ProgressRequest represents the payload sent by the Flutter client to report watch progression
type ProgressRequest struct {
	MediaID                int  `json:"media_id"`
	CurrentPositionSeconds int  `json:"current_position_seconds"`
	Duration               int  `json:"duration"` // client informs server of media duration (learned from player)
	IsFinished             bool `json:"is_finished"`
	// ClientUpdatedAt (RFC3339) dates a play that happened before this request:
	// an offline session being replayed on reconnection. It is what makes that
	// replay safe — the write is skipped when the stored row is more recent, so
	// a week-old episode watched on a plane cannot rewind what a phone did
	// yesterday. A live heartbeat leaves it empty, which means "now".
	ClientUpdatedAt string `json:"client_updated_at,omitempty"`
}

// sqliteTimeLayout is the shape CURRENT_TIMESTAMP writes. Progress timestamps
// are compared as text, so anything this handler writes has to match it
// exactly — same layout, same UTC zone — or the comparison silently degrades
// to a string ordering that means nothing.
const sqliteTimeLayout = "2006-01-02 15:04:05"

// parseClientUpdatedAt reads the client's play time. A value in the future is
// clamped to now: a device with a wrong clock would otherwise pin the row and
// block every later write.
func parseClientUpdatedAt(raw string) (time.Time, bool) {
	if strings.TrimSpace(raw) == "" {
		return time.Time{}, false
	}
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, false
	}
	now := time.Now().UTC()
	parsed = parsed.UTC()
	if parsed.After(now) {
		return now, true
	}
	return parsed, true
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

	// When the play is being replayed after the fact, it carries its own time
	// and only wins if nothing more recent has landed since. A live heartbeat
	// is stamped now and always wins, which is the behaviour this endpoint has
	// always had.
	replayedAt, isReplay := parseClientUpdatedAt(req.ClientUpdatedAt)
	stamp := time.Now().UTC()
	if isReplay {
		stamp = replayedAt
	}

	// The guard lives in the ON CONFLICT clause rather than in a read-then-write
	// here: two devices reconnecting at the same second would otherwise both
	// read "older" and both write.
	query := `
		INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(user_id, media_id) DO UPDATE SET
			current_position_seconds = excluded.current_position_seconds,
			is_finished = excluded.is_finished,
			updated_at = excluded.updated_at
		WHERE ? = 0 OR progressions.updated_at IS NULL OR progressions.updated_at <= excluded.updated_at
	`
	guard := 0
	if isReplay {
		guard = 1
	}
	_, err := database.DB.Exec(query, userID, req.MediaID, req.CurrentPositionSeconds,
		isFinished, stamp.Format(sqliteTimeLayout), guard)
	if err != nil {
		log.Printf("Progress error: failed to update progression: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	// A refused replay must not be answered with what it asked for: the client
	// adopts this reply, and telling it "finished" when the row says otherwise
	// would put the wrong badge on the episode until the next full reload.
	if isReplay {
		var storedPosition int
		var storedFinished bool
		if err := database.DB.QueryRow(
			"SELECT current_position_seconds, is_finished FROM progressions WHERE user_id = ? AND media_id = ?",
			userID, req.MediaID,
		).Scan(&storedPosition, &storedFinished); err == nil {
			isFinished = storedFinished
			req.CurrentPositionSeconds = storedPosition
		}
	}

	var mediaType string
	_ = database.DB.QueryRow(
		"SELECT type FROM medias WHERE id = ? LIMIT 1", req.MediaID,
	).Scan(&mediaType)
	UnhideContinueWatchingOnProgress(userID, req.MediaID, mediaType, req.CurrentPositionSeconds)

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
