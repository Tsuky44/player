package handlers

import (
	"database/sql"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/streamcache"

	"github.com/julienschmidt/httprouter"
)

var (
	streamLookupStmt *sql.Stmt
	streamDebug      = flag.Bool("stream-debug", false, "Log per-request /stream timing metrics")

	errInvalidStreamType = errors.New("invalid stream type")
	errEmptyFilePath     = errors.New("empty file path")
)

// InitStream prepares the prepared statement used by the /stream hot path.
func InitStream() error {
	var err error
	streamLookupStmt, err = database.DB.Prepare(
		"SELECT file_path, type FROM medias WHERE id = ?",
	)
	return err
}

// StreamMedia handles video streaming with Range Request support (GET /stream?media_id=...)
func StreamMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	start := time.Now()

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

	entry, err := resolveStreamEntry(mediaID)
	if err != nil {
		switch {
		case errors.Is(err, sql.ErrNoRows):
			http.Error(w, "media not found in database", http.StatusNotFound)
		case os.IsNotExist(err):
			http.Error(w, "physical file not found on server", http.StatusNotFound)
		case errors.Is(err, errInvalidStreamType):
			http.Error(w, "this media type cannot be streamed", http.StatusBadRequest)
		case errors.Is(err, errEmptyFilePath):
			http.Error(w, "media does not have an associated file path", http.StatusBadRequest)
		default:
			log.Printf("Stream error media_id=%d: %v", mediaID, err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
		return
	}

	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", entry.ContentType)
	w.Header().Set("Content-Disposition", "inline")

	file, err := os.Open(entry.FilePath)
	if err != nil {
		if os.IsNotExist(err) {
			streamcache.Global().Invalidate(mediaID)
			http.Error(w, "physical file not found on server", http.StatusNotFound)
		} else {
			log.Printf("Stream open error media_id=%d: %v", mediaID, err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
		return
	}
	defer file.Close()

	http.ServeContent(w, r, entry.FilePath, entry.ModTime, file)

	if *streamDebug {
		log.Printf("stream metric media_id=%d range=%q bytes=%d duration_ms=%d",
			mediaID, r.Header.Get("Range"), entry.FileSize, time.Since(start).Milliseconds())
	}
}

func resolveStreamEntry(mediaID int) (*streamcache.Entry, error) {
	if cached, ok := streamcache.Global().Get(mediaID); ok {
		return cached, nil
	}

	var filePath, mediaType string
	err := streamLookupStmt.QueryRow(mediaID).Scan(&filePath, &mediaType)
	if err != nil {
		return nil, err
	}

	if mediaType != string(models.TypeMovie) && mediaType != string(models.TypeEpisode) {
		return nil, errInvalidStreamType
	}
	if filePath == "" {
		return nil, errEmptyFilePath
	}

	size, modTime, err := streamcache.StatFile(filePath)
	if err != nil {
		return nil, err
	}

	entry := &streamcache.Entry{
		FilePath:    filePath,
		FileSize:    size,
		ModTime:     modTime,
		ContentType: streamcache.ContentTypeForPath(filePath),
		MediaType:   mediaType,
	}
	streamcache.Global().Put(mediaID, entry)
	return entry, nil
}
