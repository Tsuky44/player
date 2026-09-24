package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
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

// sqliteTimeLayout is the legacy UTC shape written by CURRENT_TIMESTAMP.
// New progress uses the same prefix with fixed fractional precision so both
// generations remain ordered chronologically by SQLite text comparisons.
const sqliteTimeLayout = "2006-01-02 15:04:05"

// Fixed precision keeps text ordering while distinguishing rapid play/unwatch events.
const progressTimeLayout = "2006-01-02 15:04:05.000000000"

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

// watchedThresholdPercent est la part d'un média à partir de laquelle il
// compte comme vu : pour la progression d'un compte comme pour la destruction
// d'un lien de partage à usage unique.
const watchedThresholdPercent = 90.0

// reachedWatchedThreshold dit si une lecture arrivée à positionSeconds a vu le
// média. Une durée inconnue ne permet pas de le dire.
func reachedWatchedThreshold(positionSeconds, durationSeconds int) bool {
	if durationSeconds <= 0 || positionSeconds <= 0 {
		return false
	}
	return float64(positionSeconds)/float64(durationSeconds)*100 >= watchedThresholdPercent
}

// UpdateProgress handles the streaming heartbeat and saves progress (POST /api/progress)
func UpdateProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req ProgressRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	if req.MediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media_id")
		return
	}

	// A duration the client measured fills in one the probe never found. Only
	// from someone actually playing the media: the column is shared by every
	// account, and any account could otherwise write whatever it liked into
	// the progress bars and "watched" thresholds of everyone else.
	effectiveDuration := req.Duration
	if req.Duration > 0 && PlaybackTickets.Holds(userID, req.MediaID) {
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

	isFinished := req.IsFinished || reachedWatchedThreshold(req.CurrentPositionSeconds, effectiveDuration)

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
		isFinished, stamp.Format(progressTimeLayout), guard)
	if err != nil {
		log.Printf("Progress error: failed to update progression: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
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

var (
	errMediaNotFound    = errors.New("media not found")
	errMediaNotPlayable = errors.New("media cannot be marked as watched")
)

// watchedWriter is all applyWatched needs of a database handle, so the same
// write runs directly for a single media and inside the transaction a whole
// season opens — one verdict, written one way.
type watchedWriter interface {
	Exec(query string, args ...interface{}) (sql.Result, error)
	QueryRow(query string, args ...interface{}) *sql.Row
}

// applyWatched records the watched verdict of one media for one user and
// returns the position the row holds afterwards.
func applyWatched(db watchedWriter, userID, mediaID int, watched bool) (int, error) {
	var mediaType string
	var duration int
	err := db.QueryRow(
		"SELECT type, COALESCE(duration, 0) FROM medias WHERE id = ?",
		mediaID,
	).Scan(&mediaType, &duration)
	if err == sql.ErrNoRows {
		return 0, errMediaNotFound
	}
	if err != nil {
		return 0, err
	}
	if mediaType != string(models.TypeMovie) && mediaType != string(models.TypeEpisode) {
		return 0, errMediaNotPlayable
	}

	now := time.Now().UTC().Format(progressTimeLayout)
	position := 0

	if watched {
		_ = db.QueryRow(
			"SELECT COALESCE(current_position_seconds, 0) FROM progressions WHERE user_id = ? AND media_id = ?",
			userID, mediaID,
		).Scan(&position)
		if duration > 0 {
			position = duration
		} else if position <= 0 {
			position = 1
		}

		_, err = db.Exec(`
			INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
			VALUES (?, ?, ?, 1, ?)
			ON CONFLICT(user_id, media_id) DO UPDATE SET
				current_position_seconds = excluded.current_position_seconds,
				is_finished = 1,
				updated_at = excluded.updated_at
		`, userID, mediaID, position, now)
		if err != nil {
			return 0, err
		}
		return position, nil
	}

	result, err := db.Exec(`
		UPDATE progressions
		SET is_finished = 0, updated_at = ?
		WHERE user_id = ? AND media_id = ?
	`, now, userID, mediaID)
	if err != nil {
		return 0, err
	}
	// Nothing stored means nothing watched: there is no progress to rewind.
	if rows, _ := result.RowsAffected(); rows == 0 {
		return 0, nil
	}
	_ = db.QueryRow(
		"SELECT COALESCE(current_position_seconds, 0) FROM progressions WHERE user_id = ? AND media_id = ?",
		userID, mediaID,
	).Scan(&position)
	return position, nil
}

// SetMediaWatched marks or unmarks a movie/episode as watched (POST /api/media/:id/watched).
func SetMediaWatched(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}

	var req watchedRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	position, err := applyWatched(database.DB, userID, mediaID, req.Watched)
	switch {
	case errors.Is(err, errMediaNotFound):
		writeJSONError(w, http.StatusNotFound, "Media not found")
		return
	case errors.Is(err, errMediaNotPlayable):
		writeJSONError(w, http.StatusBadRequest, "Only movies and episodes can be marked as watched")
		return
	case err != nil:
		log.Printf("Watched error: failed to update media %d: %v", mediaID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":                   "success",
		"is_finished":              req.Watched,
		"current_position_seconds": position,
	})
}

// maxWatchedBatch borne une requête de lot : une saison tient largement
// dedans, une boucle partie en vrille non.
const maxWatchedBatch = 500

type watchedBatchRequest struct {
	MediaIDs []int `json:"media_ids"`
	Watched  bool  `json:"watched"`
}

type watchedBatchEntry struct {
	MediaID    int  `json:"media_id"`
	IsFinished bool `json:"is_finished"`
	Position   int  `json:"current_position_seconds"`
}

// SetMediaWatchedBatch marque un lot de médias — en pratique une saison
// entière — vu ou non vu en une requête (POST /api/progress/watched).
//
// Vingt épisodes cochés un par un, c'est vingt allers-retours et une liste qui
// clignote vingt fois ; ici le client envoie la saison et reçoit son verdict.
// Les identifiants introuvables ou non lisibles (une saison, une série) sont
// ignorés plutôt que de faire échouer le reste : le geste porte sur ce qui est
// regardable.
func SetMediaWatchedBatch(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req watchedBatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if len(req.MediaIDs) == 0 {
		writeJSONError(w, http.StatusBadRequest, "media_ids is required")
		return
	}
	if len(req.MediaIDs) > maxWatchedBatch {
		writeJSONError(w, http.StatusBadRequest, "Too many media IDs")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("Watched batch error: failed to open transaction: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	defer tx.Rollback()

	updated := make([]watchedBatchEntry, 0, len(req.MediaIDs))
	seen := make(map[int]bool, len(req.MediaIDs))
	for _, mediaID := range req.MediaIDs {
		if mediaID <= 0 || seen[mediaID] {
			continue
		}
		seen[mediaID] = true

		position, err := applyWatched(tx, userID, mediaID, req.Watched)
		if errors.Is(err, errMediaNotFound) || errors.Is(err, errMediaNotPlayable) {
			continue
		}
		if err != nil {
			log.Printf("Watched batch error: failed to update media %d: %v", mediaID, err)
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
			return
		}
		updated = append(updated, watchedBatchEntry{
			MediaID:    mediaID,
			IsFinished: req.Watched,
			Position:   position,
		})
	}

	if err := tx.Commit(); err != nil {
		log.Printf("Watched batch error: failed to commit: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "success",
		"watched": req.Watched,
		"updated": updated,
	})
}

// GetProgress returns the watch progression for a specific media ID (GET /api/progress?media_id=...)
func GetProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	mediaIDStr := r.URL.Query().Get("media_id")
	if mediaIDStr == "" {
		writeJSONError(w, http.StatusBadRequest, "media_id parameter is required")
		return
	}

	mediaID, err := strconv.Atoi(mediaIDStr)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid media_id")
		return
	}

	// Le point de reprise est lu ici juste avant une lecture : c'est le moment
	// de demander à Emby s'il en sait plus récent. Borné, jamais bloquant.
	refreshEmbyMedia(r.Context(), userID, mediaID)

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
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		}
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"current_position_seconds": currentPosition,
		"is_finished":              isFinished,
	})
}
