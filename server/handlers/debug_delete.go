package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/subtitles"

	"github.com/julienschmidt/httprouter"
)

// DebugDeleteShow deletes a show and all its children (seasons, episodes) from
// the database, removes associated subtitle files from disk, and clears
// subtitle rows. This is a debug endpoint to test re-indexing a show from
// scratch as if it just arrived on the server.
//
// POST /api/indexer/debug/delete-show?title=Game%20of%20Thrones
// POST /api/indexer/debug/delete-show/:id
func DebugDeleteShow(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	var showID int
	var showTitle string

	if idStr := ps.ByName("id"); idStr != "" {
		var err error
		showID, err = strconv.Atoi(idStr)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "Invalid show ID")
			return
		}
		err = database.DB.QueryRow(
			"SELECT title FROM medias WHERE id = ? AND type = 'show'", showID,
		).Scan(&showTitle)
		if err != nil {
			if err == sql.ErrNoRows {
				writeJSONError(w, http.StatusNotFound, "Show not found")
			} else {
				writeJSONError(w, http.StatusInternalServerError, "Database error")
			}
			return
		}
	} else {
		title := strings.TrimSpace(r.URL.Query().Get("title"))
		if title == "" {
			writeJSONError(w, http.StatusBadRequest, "Missing 'title' query parameter")
			return
		}
		err := database.DB.QueryRow(
			"SELECT id, title FROM medias WHERE type = 'show' AND title LIKE ?",
			"%"+title+"%",
		).Scan(&showID, &showTitle)
		if err != nil {
			if err == sql.ErrNoRows {
				writeJSONError(w, http.StatusNotFound, "No show found matching '"+title+"'")
			} else {
				writeJSONError(w, http.StatusInternalServerError, "Database error")
			}
			return
		}
	}

	log.Printf("DebugDeleteShow: removing show %q (id=%d) and all children", showTitle, showID)

	// 1. Collect all episode IDs (direct children of seasons under this show).
	rows, err := database.DB.Query(`
		SELECT ep.id
		FROM medias ep
		JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
		WHERE ep.type = 'episode' AND season.parent_id = ?`, showID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Failed to query episodes")
		return
	}
	var episodeIDs []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			continue
		}
		episodeIDs = append(episodeIDs, id)
	}
	rows.Close()

	// 2. Delete subtitle files and rows for each episode.
	subtitleDir := subtitles.OutputDir()
	deletedSubs := 0
	for _, epID := range episodeIDs {
		deletedSubs += deleteSubtitleFiles(subtitleDir, epID)
		_ = subtitles.ClearForMedia(epID)
	}

	// 3. Delete subtitle files for the show itself (unlikely but safe).
	deletedSubs += deleteSubtitleFiles(subtitleDir, showID)
	_ = subtitles.ClearForMedia(showID)

	// 4. Delete episodes, seasons, and the show from the database.
	// SQLite cascade should handle children, but we do it explicitly to be safe.
	_, _ = database.DB.Exec(`
		DELETE FROM medias WHERE type = 'episode'
		AND parent_id IN (SELECT id FROM medias WHERE type = 'season' AND parent_id = ?)`, showID)
	_, _ = database.DB.Exec(
		"DELETE FROM medias WHERE type = 'season' AND parent_id = ?", showID)
	_, _ = database.DB.Exec(
		"DELETE FROM medias WHERE id = ? AND type = 'show'", showID)

	// 5. Clean up any empty seasons/shows that might remain.
	_, _ = database.DB.Exec(`
		DELETE FROM medias WHERE type = 'season'
		AND id NOT IN (SELECT DISTINCT parent_id FROM medias WHERE type = 'episode' AND parent_id IS NOT NULL)`)
	_, _ = database.DB.Exec(`
		DELETE FROM medias WHERE type = 'show'
		AND id NOT IN (SELECT DISTINCT parent_id FROM medias WHERE type = 'season' AND parent_id IS NOT NULL)`)

	log.Printf("DebugDeleteShow: removed %d episodes, %d subtitle files for show %q",
		len(episodeIDs), deletedSubs, showTitle)

	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":          "success",
		"show_id":         showID,
		"show_title":      showTitle,
		"episodes_removed": len(episodeIDs),
		"subtitle_files_deleted": deletedSubs,
		"message":         "Show deleted. Trigger a scan to re-index it.",
	})
}

// deleteSubtitleFiles removes all .vtt files matching the media ID prefix
// from the subtitle output directory. Returns the number of files deleted.
func deleteSubtitleFiles(dir string, mediaID int) int {
	pattern := filepath.Join(dir, "m"+strconv.Itoa(mediaID)+".*.vtt")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return 0
	}
	count := 0
	for _, f := range matches {
		if err := os.Remove(f); err != nil {
			log.Printf("DebugDeleteShow: failed to remove %s: %v", f, err)
			continue
		}
		count++
	}
	return count
}
