package handlers

import (
	"database/sql"
	"log"
	"net/http"
	"os"
	"strconv"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// StreamMedia handles video streaming with Range Request support (GET /stream?media_id=...)
func StreamMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	// Enable CORS for streaming (extremely important for Flutter web/desktop clients)
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Authorization")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	mediaIDStr := r.URL.Query().Get("media_id")
	if mediaIDStr == "" {
		http.Error(w, "media_id query parameter is required", http.StatusBadRequest)
		return
	}

	mediaID, err := strconv.Atoi(mediaIDStr)
	if err != nil {
		http.Error(w, "invalid media_id parameter", http.StatusBadRequest)
		return
	}

	// Fetch media from DB
	var filePath string
	var mediaType string
	var title string

	err = database.DB.QueryRow(
		"SELECT title, file_path, type FROM medias WHERE id = ?",
		mediaID,
	).Scan(&title, &filePath, &mediaType)

	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, "media not found in database", http.StatusNotFound)
		} else {
			log.Printf("Stream error: failed to query database: %v", err)
			http.Error(w, "internal database error", http.StatusInternalServerError)
		}
		return
	}

	// Verify the media type can actually be streamed
	if mediaType != string(models.TypeMovie) && mediaType != string(models.TypeEpisode) {
		http.Error(w, "this media type cannot be streamed", http.StatusBadRequest)
		return
	}

	if filePath == "" {
		http.Error(w, "media does not have an associated file path", http.StatusBadRequest)
		return
	}

	// Verify file exists on disk
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		log.Printf("Stream error: physical file not found for media %d (%s) at path %s", mediaID, title, filePath)
		http.Error(w, "physical file not found on server", http.StatusNotFound)
		return
	}

	log.Printf("Stream: Serving file %s for media_id %d", filePath, mediaID)

	// Set Content-Disposition to inline (not attachment) so players can render it inline
	w.Header().Set("Content-Disposition", "inline")

	// http.ServeFile natively supports:
	// - Content-Type sniffing
	// - Last-Modified / ETag headers
	// - HTTP Range Requests (crucial for seeking and chunk-based streaming)
	http.ServeFile(w, r, filePath)
}
