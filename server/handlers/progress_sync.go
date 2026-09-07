package handlers

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
)

// PortableProgress identifies content, never an ID or a user on another server.
// For episodes TMDBID is the show's ID, not the episode's metadata ID.
type PortableProgress struct {
	Type      string `json:"type"`
	TMDBID    int    `json:"tmdb_id"`
	Season    int    `json:"season_number"`
	Episode   int    `json:"episode_number"`
	Position  int    `json:"current_position_seconds"`
	Finished  bool   `json:"is_finished"`
	UpdatedAt string `json:"updated_at"`
}

const portableMedia = `SELECT m.id, m.type,
 CASE WHEN m.type = 'movie' THEN m.tmdb_id ELSE show.tmdb_id END,
 CASE WHEN m.type = 'episode' THEN season.season_number ELSE 0 END,
 CASE WHEN m.type = 'episode' THEN m.episode_number ELSE 0 END
 FROM medias m
 LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
 LEFT JOIN medias show ON season.parent_id = show.id AND show.type = 'show'
 WHERE (m.type = 'movie' AND m.tmdb_id > 0)
 OR (m.type = 'episode' AND show.tmdb_id > 0 AND season.season_number >= 0 AND m.episode_number > 0)`

func ExportProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	exportPortableProgress(w, userID, r.URL.Query().Get("media_id"))
}

func exportPortableProgress(w http.ResponseWriter, userID int, mediaID string) {
	rows, err := database.DB.Query(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
 SELECT c.type, c.tmdb, c.season, c.episode, p.current_position_seconds, p.is_finished, p.updated_at
 FROM content c JOIN progressions p ON p.media_id = c.id WHERE p.user_id = ? AND (? = '' OR c.id = ?)`, userID, mediaID, mediaID)
	if err != nil {
		http.Error(w, "Unable to read progress", 500)
		return
	}
	defer rows.Close()
	entries := []PortableProgress{}
	for rows.Next() {
		var entry PortableProgress
		var stamp sql.NullString
		if err := rows.Scan(&entry.Type, &entry.TMDBID, &entry.Season, &entry.Episode, &entry.Position, &entry.Finished, &stamp); err != nil {
			http.Error(w, "Unable to read progress", 500)
			return
		}
		date := scanSQLiteTime(stamp)
		if date.IsZero() {
			continue
		}
		entry.UpdatedAt = date.UTC().Format(time.RFC3339Nano)
		entries = append(entries, entry)
	}
	if rows.Err() != nil {
		http.Error(w, "Unable to read progress", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(entries)
}

func ImportProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var entries []PortableProgress
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&entries); err != nil || len(entries) > 500 {
		http.Error(w, "Invalid progress batch", 400)
		return
	}
	for _, e := range entries {
		if (e.Type != "movie" && e.Type != "episode") || e.TMDBID <= 0 || e.Position < 0 ||
			(e.Type == "episode" && (e.Season < 0 || e.Episode <= 0)) ||
			(e.Type == "movie" && (e.Season != 0 || e.Episode != 0)) {
			http.Error(w, "Invalid content identity", 400)
			return
		}
		if _, err := time.Parse(time.RFC3339Nano, e.UpdatedAt); err != nil {
			http.Error(w, "Invalid progress date", 400)
			return
		}
	}
	tx, err := database.DB.Begin()
	if err != nil {
		http.Error(w, "Unable to save progress", 500)
		return
	}
	defer tx.Rollback()
	for _, e := range entries {
		stamp, _ := parseClientUpdatedAt(e.UpdatedAt)
		_, err = tx.Exec(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
   INSERT INTO progressions(user_id, media_id, current_position_seconds, is_finished, updated_at)
   SELECT ?, id, ?, ?, ? FROM content WHERE type = ? AND tmdb = ? AND season = ? AND episode = ?
   ON CONFLICT(user_id, media_id) DO UPDATE SET
   current_position_seconds = excluded.current_position_seconds,
   is_finished = excluded.is_finished, updated_at = excluded.updated_at
   WHERE progressions.updated_at IS NULL OR progressions.updated_at < excluded.updated_at`,
			userID, e.Position, e.Finished, stamp.Format(progressTimeLayout), e.Type, e.TMDBID, e.Season, e.Episode)
		if err != nil {
			http.Error(w, "Unable to save progress", 500)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, "Unable to save progress", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "success"})
}
