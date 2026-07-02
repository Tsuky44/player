package streaming

import (
	"context"
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
	"time"

	"github.com/google/uuid"
	"github.com/julienschmidt/httprouter"
)

// Handler wires the HLS transcoding endpoints to their dependencies.
type Handler struct {
	manager *SessionManager
	db      *sql.DB
}

// NewHandler creates a streaming handler.
func NewHandler(db *sql.DB) *Handler {
	return &Handler{
		manager: NewSessionManager(),
		db:      db,
	}
}

func writeCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Authorization, Content-Type")
}

// Dispatch routes every /api/v1/stream/* request. The path is parsed manually
// to keep a single httprouter catch-all and avoid wildcard conflicts.
//
//	POST   /api/v1/stream/{mediaID}/start                      → create session (JSON)
//	GET    /api/v1/stream/{mediaID}/{sessionID}/{file}         → serve playlist/segment
//	DELETE /api/v1/stream/{mediaID}/{sessionID}                → destroy session
func (h *Handler) Dispatch(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	writeCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	rest := strings.TrimPrefix(r.URL.Path, "/api/v1/stream/")
	parts := strings.Split(strings.Trim(rest, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}

	mediaID, err := strconv.Atoi(parts[0])
	if err != nil {
		http.Error(w, "invalid media_id", http.StatusBadRequest)
		return
	}

	switch {
	case len(parts) == 2 && parts[1] == "start" && r.Method == http.MethodPost:
		h.handleStart(w, r, mediaID)
	case len(parts) == 2 && r.Method == http.MethodDelete:
		h.manager.DestroySession(parts[1])
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"destroyed"}`))
	case len(parts) == 3 && r.Method == http.MethodGet:
		h.handleServeFile(w, r, parts[1], parts[2])
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// startResponse is the JSON body returned when a session is created. The client
// opens MasterURL directly with media_kit (mpv resolves child playlists/segments
// relative to it — no server-side rewriting needed).
type startResponse struct {
	SessionID   string  `json:"session_id"`
	MasterURL   string  `json:"master_url"`
	Duration    float64 `json:"duration"`
	StartOffset int     `json:"start_offset"`
	Quality     string  `json:"quality"`
}

func (h *Handler) handleStart(w http.ResponseWriter, r *http.Request, mediaID int) {
	startedAt := time.Now()

	quality := r.URL.Query().Get("quality")
	if quality == "" {
		quality = "720p"
	}
	startSeconds := atoiDefault(r.URL.Query().Get("start"), 0)
	audioIndex := atoiDefault(r.URL.Query().Get("audio"), 0)

	inputPath, err := h.getMediaFilePath(mediaID)
	if err != nil {
		log.Printf("HLS start: media %d: %v", mediaID, err)
		http.Error(w, "media not found", http.StatusNotFound)
		return
	}

	probe, err := ProbeTracks(inputPath)
	if err != nil {
		log.Printf("HLS start: probe failed for media %d: %v", mediaID, err)
		probe = &ProbeResult{}
	}
	if audioIndex < 0 || audioIndex >= len(probe.Audio) {
		audioIndex = 0
	}

	tmpDir, err := os.MkdirTemp("", "hls-*")
	if err != nil {
		log.Printf("HLS start: mkdtemp: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:       inputPath,
		Quality:         quality,
		StartSeconds:    startSeconds,
		TmpDir:          tmpDir,
		Probe:           probe,
		SegmentDuration: 4,
		AudioTypedIndex: audioIndex,
	})

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)

	sessionID := uuid.New().String()
	session := &TranscodeSession{
		ID:          sessionID,
		MediaID:     mediaID,
		Quality:     quality,
		AudioIndex:  audioIndex,
		StartOffset: startSeconds,
		TmpDir:      tmpDir,
		Probe:       probe,
		ctx:         ctx,
		cancel:      cancel,
		cmd:         cmd,
	}
	cmd.Stderr = &session.stderr

	if err := session.Start(); err != nil {
		cancel()
		os.RemoveAll(tmpDir)
		log.Printf("HLS start: ffmpeg start failed: %v", err)
		http.Error(w, "failed to start transcoding", http.StatusInternalServerError)
		return
	}
	h.manager.CreateSession(session)

	// The video variant playlist guarantees the master has been written too.
	if err := session.WaitForFile("stream_0.m3u8", 30*time.Second); err != nil {
		log.Printf("HLS start: %v (session %s)", err, sessionID)
		h.manager.DestroySession(sessionID)
		http.Error(w, "transcoding timeout", http.StatusServiceUnavailable)
		return
	}

	baseURL := getBaseURL(r)
	resp := startResponse{
		SessionID:   sessionID,
		MasterURL:   fmt.Sprintf("%s/api/v1/stream/%d/%s/master.m3u8", baseURL, mediaID, sessionID),
		Duration:    probe.Duration,
		StartOffset: startSeconds,
		Quality:     quality,
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_ = json.NewEncoder(w).Encode(resp)

	log.Printf("HLS: session %s media %d quality=%s start=%ds audio=%d ready in %v",
		sessionID, mediaID, quality, startSeconds, audioIndex, time.Since(startedAt))
}

// handleServeFile streams a playlist or segment straight from the session temp
// dir. No playlist rewriting is needed because mpv resolves relative child URIs
// against the master URL it fetched.
func (h *Handler) handleServeFile(w http.ResponseWriter, r *http.Request, sessionID, filename string) {
	session, ok := h.manager.GetSession(sessionID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	filename = filepath.Base(filename) // path-traversal guard
	if idx, isSeg := parseVideoSegmentIndex(filename); isSeg {
		session.NoteSegment(idx)
	} else {
		session.Touch()
	}

	filePath := filepath.Join(session.TmpDir, filename)
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		http.Error(w, "file not ready", http.StatusNotFound)
		return
	}

	switch strings.ToLower(filepath.Ext(filename)) {
	case ".ts":
		w.Header().Set("Content-Type", "video/mp2t")
	case ".m3u8":
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	case ".vtt":
		w.Header().Set("Content-Type", "text/vtt")
	default:
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeFile(w, r, filePath)
}

func (h *Handler) getMediaFilePath(mediaID int) (string, error) {
	var filePath string
	if err := h.db.QueryRow("SELECT file_path FROM medias WHERE id = ?", mediaID).Scan(&filePath); err != nil {
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

// parseVideoSegmentIndex extracts N from "stream_0_<N>.ts" (the video rendition).
func parseVideoSegmentIndex(name string) (int, bool) {
	if !strings.HasPrefix(name, "stream_0_") || !strings.HasSuffix(name, ".ts") {
		return 0, false
	}
	mid := strings.TrimSuffix(strings.TrimPrefix(name, "stream_0_"), ".ts")
	n, err := strconv.Atoi(mid)
	if err != nil {
		return 0, false
	}
	return n, true
}

func atoiDefault(s string, def int) int {
	if s == "" {
		return def
	}
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}

// getBaseURL derives scheme://host from the request, honoring a reverse proxy.
func getBaseURL(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if fwd := r.Header.Get("X-Forwarded-Proto"); fwd != "" {
		scheme = fwd
	}
	return scheme + "://" + r.Host
}
