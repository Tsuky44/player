package streaming

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/julienschmidt/httprouter"
)

// Handler holds the dependencies for HLS streaming endpoints.
type Handler struct {
	manager *SessionManager
	db      *sql.DB
}

// NewHandler creates a new streaming handler.
func NewHandler(db *sql.DB) *Handler {
	return &Handler{
		manager: NewSessionManager(),
		db:      db,
	}
}

// Dispatch is the single entry point for all HLS streaming requests.
// It parses the URL path manually to avoid httprouter wildcard conflicts.
// Routes:
//   GET    /api/v1/stream/{media_id}/master.m3u8         → master playlist
//   GET    /api/v1/stream/{media_id}/{session_id}/variant.m3u8 → variant playlist
//   GET    /api/v1/stream/{media_id}/{session_id}/{filename}   → serve file (.ts/.vtt)
//   DELETE /api/v1/stream/{media_id}/{session_id}        → destroy session
func (h *Handler) Dispatch(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Authorization")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	// Extract the path after /api/v1/stream/
	rest := strings.TrimPrefix(r.URL.Path, "/api/v1/stream/")
	parts := strings.Split(rest, "/")
	if len(parts) == 0 || parts[0] == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}

	mediaID, err := strconv.Atoi(parts[0])
	if err != nil {
		http.Error(w, "invalid media_id", http.StatusBadRequest)
		return
	}

	// /api/v1/stream/{media_id}/master.m3u8
	if len(parts) == 2 && parts[1] == "master.m3u8" && r.Method == "GET" {
		h.handleMasterPlaylist(w, r, mediaID)
		return
	}

	// /api/v1/stream/{media_id}/{session_id}  (DELETE → destroy session)
	if len(parts) == 2 && r.Method == "DELETE" {
		h.handleDestroySession(w, r, parts[1])
		return
	}

	// /api/v1/stream/{media_id}/{session_id}/variant.m3u8
	if len(parts) == 3 && parts[2] == "variant.m3u8" && r.Method == "GET" {
		h.handleVariantPlaylist(w, r, mediaID, parts[1])
		return
	}

	// /api/v1/stream/{media_id}/{session_id}/{filename}
	if len(parts) == 3 && r.Method == "GET" {
		h.handleServeFile(w, r, parts[1], parts[2])
		return
	}

	http.Error(w, "not found", http.StatusNotFound)
}

// getMediaFilePath queries the database for the file path of a media item.
func (h *Handler) getMediaFilePath(mediaID int) (string, error) {
	var filePath string
	err := h.db.QueryRow("SELECT file_path FROM medias WHERE id = ?", mediaID).Scan(&filePath)
	if err != nil {
		return "", err
	}
	if filePath == "" {
		return "", fmt.Errorf("media has no file path")
	}
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		return "", fmt.Errorf("physical file not found: %s", filePath)
	}
	return filePath, nil
}

// handleMasterPlaylist creates a transcoding session and returns the master playlist.
func (h *Handler) handleMasterPlaylist(w http.ResponseWriter, r *http.Request, mediaID int) {

	quality := r.URL.Query().Get("quality")
	if quality == "" {
		quality = "720p"
	}

	startStr := r.URL.Query().Get("start")
	if startStr == "" {
		startStr = "0"
	}

	// Get file path from DB
	inputPath, err := h.getMediaFilePath(mediaID)
	if err != nil {
		log.Printf("HLS MasterPlaylist: media %d: %v", mediaID, err)
		http.Error(w, "media not found", http.StatusNotFound)
		return
	}

	// Probe tracks
	probe, err := ProbeTracks(inputPath)
	if err != nil {
		log.Printf("HLS MasterPlaylist: probe failed for media %d: %v", mediaID, err)
		// Continue without probe — FFmpeg will use defaults
		probe = &ProbeResult{}
	}

	// Create temp directory
	tmpDir, err := os.MkdirTemp("", "hls-*")
	if err != nil {
		log.Printf("HLS MasterPlaylist: failed to create temp dir: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Build FFmpeg command
	sessionID := uuid.New().String()
	ffmpegArgs := BuildFFmpegArgs(inputPath, quality, startStr, tmpDir, probe)

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "ffmpeg", ffmpegArgs...)

	session := &TranscodeSession{
		ID:      sessionID,
		MediaID: mediaID,
		Quality: quality,
		TmpDir:  tmpDir,
		ctx:     ctx,
		cancel:  cancel,
		cmd:     cmd,
	}

	// Capture stderr for debugging
	cmd.Stderr = &session.stderr

	// Start FFmpeg
	if err := session.Start(); err != nil {
		log.Printf("HLS MasterPlaylist: failed to start ffmpeg: %v", err)
		os.RemoveAll(tmpDir)
		http.Error(w, "failed to start transcoding", http.StatusInternalServerError)
		return
	}

	log.Printf("HLS: Started session %s for media %d quality %s start %s", sessionID, mediaID, quality, startStr)

	// Register session
	h.manager.CreateSession(session)

	// Extract subtitles in background (non-blocking)
	ExtractSubtitles(inputPath, tmpDir, probe)

	// Wait for variant.m3u8 to appear
	if err := session.WaitForVariantPlaylist(15 * time.Second); err != nil {
		log.Printf("HLS MasterPlaylist: %v for session %s", err, sessionID)
		h.manager.DestroySession(sessionID)
		http.Error(w, "transcoding timeout", http.StatusServiceUnavailable)
		return
	}

	// Build base URL from request
	baseURL := getBaseURL(r)

	// Generate and return master playlist
	masterPlaylist := GenerateMasterPlaylist(session, probe, baseURL)

	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Session-Id", sessionID)
	w.Header().Set("X-Total-Duration", fmt.Sprintf("%.3f", probe.Duration))
	w.Write([]byte(masterPlaylist))
}

// handleVariantPlaylist serves the FFmpeg-generated variant playlist with absolute segment URIs.
func (h *Handler) handleVariantPlaylist(w http.ResponseWriter, r *http.Request, mediaID int, sessionID string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")

	session, ok := h.manager.GetSession(sessionID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	session.Touch()

	playlistPath := filepath.Join(session.TmpDir, "variant.m3u8")

	// Read the variant playlist generated by FFmpeg
	content, err := os.ReadFile(playlistPath)
	if err != nil {
		http.Error(w, "playlist not ready", http.StatusNotFound)
		return
	}

	// Rewrite segment URIs to absolute URLs
	baseURL := getBaseURL(r)
	segmentBase := fmt.Sprintf("%s/api/v1/stream/%d/%s", baseURL, session.MediaID, session.ID)
	rewritten := rewriteSegmentURIs(string(content), segmentBase)

	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write([]byte(rewritten))
}

// handleServeFile serves any file (segment .ts or subtitle .vtt) from the session's temp directory.
func (h *Handler) handleServeFile(w http.ResponseWriter, r *http.Request, sessionID string, filename string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")

	session, ok := h.manager.GetSession(sessionID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	session.Touch()

	// Security: prevent path traversal
	filename = filepath.Base(filename)

	filePath := filepath.Join(session.TmpDir, filename)

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		// File might still be generating (subtitle extraction or segment not yet produced)
		http.Error(w, "file not ready", http.StatusNotFound)
		return
	}

	// Set Content-Type based on extension
	switch strings.ToLower(filepath.Ext(filename)) {
	case ".ts":
		w.Header().Set("Content-Type", "video/mp2t")
	case ".vtt":
		w.Header().Set("Content-Type", "text/vtt")
	case ".m3u8":
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	default:
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeFile(w, r, filePath)
}

// handleDestroySession kills the FFmpeg process and cleans up the session.
func (h *Handler) handleDestroySession(w http.ResponseWriter, r *http.Request, sessionID string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")

	h.manager.DestroySession(sessionID)

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"destroyed"}`))
}

// getBaseURL extracts the base URL (scheme://host) from the request.
func getBaseURL(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	// Allow proxy-forwarded scheme
	if fwd := r.Header.Get("X-Forwarded-Proto"); fwd != "" {
		scheme = fwd
	}
	return scheme + "://" + r.Host
}

// rewriteSegmentURIs converts relative segment filenames in the variant playlist
// to absolute URLs pointing to the server's segment endpoint.
func rewriteSegmentURIs(playlist, segmentBase string) string {
	lines := strings.Split(playlist, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		// Skip comments and empty lines
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		// This is a segment URI — make it absolute
		lines[i] = segmentBase + "/" + trimmed
	}
	return strings.Join(lines, "\n")
}
