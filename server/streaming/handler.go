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

	// /api/v1/stream/{media_id}/{session_id}/{filename}
	if len(parts) == 3 && r.Method == "GET" {
		// FFmpeg-generated variant playlists (.m3u8) need their segment URIs
		// rewritten to absolute URLs; everything else (.ts, .vtt) is served raw.
		if strings.HasSuffix(parts[2], ".m3u8") {
			h.handleChildPlaylist(w, r, parts[1], parts[2])
		} else {
			h.handleServeFile(w, r, parts[1], parts[2])
		}
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
	startTime := time.Now()

	quality := r.URL.Query().Get("quality")
	if quality == "" {
		quality = "720p"
	}

	startStr := r.URL.Query().Get("start")
	if startStr == "" {
		startStr = "0"
	}

	audioIndexStr := r.URL.Query().Get("audio_index")
	audioIndex := 0
	if audioIndexStr != "" {
		if ai, err := strconv.Atoi(audioIndexStr); err == nil && ai >= 0 {
			audioIndex = ai
		}
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

	log.Printf("HLS MasterPlaylist: probed %d audio streams and %d subtitle streams for media %d", len(probe.Audio), len(probe.Subtitles), mediaID)
	for i, sub := range probe.Subtitles {
		log.Printf("HLS MasterPlaylist: subtitle %d -> stream index %d codec %s", i, sub.Index, sub.Codec)
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
	ffmpegArgs := BuildFFmpegArgs(inputPath, quality, startStr, tmpDir, probe, audioIndex)

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "ffmpeg", ffmpegArgs...)

	session := &TranscodeSession{
		ID:         sessionID,
		MediaID:    mediaID,
		Quality:    quality,
		AudioIndex: audioIndex,
		TmpDir:     tmpDir,
		Probe:      probe,
		ctx:        ctx,
		cancel:     cancel,
		cmd:        cmd,
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

	// Extract subtitles in parallel, lightweight FFmpeg processes (no video
	// decode) so they never stall the main transcode. Fire-and-forget: the
	// master playlist is served as soon as the video is ready, and the subtitle
	// playlists/VTTs appear shortly after (text extraction is near-instant).
	startVal := 0
	fmt.Sscanf(startStr, "%d", &startVal)
	ExtractSubtitles(inputPath, tmpDir, probe, startVal, probe.Duration)

	// Wait for FFmpeg to produce the video variant playlist, which guarantees
	// the master playlist has also been written.
	if err := session.WaitForFile("stream_0.m3u8", 30*time.Second); err != nil {
		log.Printf("HLS MasterPlaylist: %v for session %s", err, sessionID)
		h.manager.DestroySession(sessionID)
		http.Error(w, "transcoding timeout", http.StatusServiceUnavailable)
		return
	}

	// Read the master playlist generated by FFmpeg and rewrite its child URIs
	// (variant playlists and EXT-X-MEDIA renditions) to absolute server URLs.
	baseURL := getBaseURL(r)
	masterPath := filepath.Join(tmpDir, "master.m3u8")
	rawMaster, err := os.ReadFile(masterPath)
	if err != nil {
		log.Printf("HLS MasterPlaylist: failed to read master for session %s: %v", sessionID, err)
		h.manager.DestroySession(sessionID)
		http.Error(w, "master playlist not ready", http.StatusServiceUnavailable)
		return
	}

	childBase := fmt.Sprintf("%s/api/v1/stream/%d/%s", baseURL, mediaID, sessionID)
	masterPlaylist := rewriteMasterPlaylist(string(rawMaster), childBase)
	// FFmpeg cannot mux subtitle-only HLS variants, so the subtitle renditions
	// are generated as separate segmented WebVTT playlists and injected here.
	masterPlaylist = injectSubtitleRenditions(masterPlaylist, probe, childBase)

	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Session-Id", sessionID)
	w.Header().Set("X-Total-Duration", fmt.Sprintf("%.3f", probe.Duration))
	w.Write([]byte(masterPlaylist))

	elapsed := time.Since(startTime)
	log.Printf("HLS: Master playlist for media %d session %s generated in %v (audio_index=%d, quality=%s)", mediaID, sessionID, elapsed, audioIndex, quality)
}

// handleChildPlaylist serves an FFmpeg-generated variant playlist (video, audio
// or subtitle rendition) and rewrites its relative segment/init URIs to absolute
// server URLs so the player fetches them through this handler.
func (h *Handler) handleChildPlaylist(w http.ResponseWriter, r *http.Request, sessionID string, filename string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")

	session, ok := h.manager.GetSession(sessionID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	session.Touch()

	// Security: prevent path traversal
	filename = filepath.Base(filename)
	playlistPath := filepath.Join(session.TmpDir, filename)

	content, err := os.ReadFile(playlistPath)
	if err != nil {
		http.Error(w, "playlist not ready", http.StatusNotFound)
		return
	}

	baseURL := getBaseURL(r)
	segmentBase := fmt.Sprintf("%s/api/v1/stream/%d/%s", baseURL, session.MediaID, session.ID)
	rewritten := rewriteChildPlaylist(string(content), segmentBase)

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

// rewriteURIAttr rewrites a relative URI="..." attribute on a tag line to an
// absolute URL. Absolute URLs (http/https) are left untouched.
func rewriteURIAttr(line, base string) string {
	const marker = "URI=\""
	idx := strings.Index(line, marker)
	if idx == -1 {
		return line
	}
	start := idx + len(marker)
	end := strings.Index(line[start:], "\"")
	if end == -1 {
		return line
	}
	uri := line[start : start+end]
	if uri == "" || strings.HasPrefix(uri, "http://") || strings.HasPrefix(uri, "https://") {
		return line
	}
	return line[:start] + base + "/" + uri + line[start+end:]
}

// rewriteChildPlaylist converts relative segment filenames and EXT-X-MAP init
// URIs in a variant playlist to absolute URLs pointing to the server.
func rewriteChildPlaylist(playlist, segmentBase string) string {
	lines := strings.Split(playlist, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			// Rewrite URI attributes on tags such as #EXT-X-MAP.
			if strings.Contains(trimmed, "URI=\"") {
				lines[i] = rewriteURIAttr(line, segmentBase)
			}
			continue
		}
		// Bare line: a segment (.ts/.vtt) URI — make it absolute.
		lines[i] = segmentBase + "/" + trimmed
	}
	return strings.Join(lines, "\n")
}

// rewriteMasterPlaylist converts the relative child-playlist references in an
// FFmpeg-generated master playlist to absolute server URLs. This covers both
// the bare #EXT-X-STREAM-INF variant lines and the URI="..." attributes on
// #EXT-X-MEDIA audio/subtitle rendition tags.
func rewriteMasterPlaylist(playlist, childBase string) string {
	lines := strings.Split(playlist, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			if strings.Contains(trimmed, "URI=\"") {
				lines[i] = rewriteURIAttr(line, childBase)
			}
			continue
		}
		// Bare line: a variant playlist (stream_N.m3u8) reference.
		lines[i] = childBase + "/" + trimmed
	}
	return strings.Join(lines, "\n")
}

// injectSubtitleRenditions adds an #EXT-X-MEDIA:TYPE=SUBTITLES entry per text
// subtitle track (pointing to the FFmpeg-generated sub_N.m3u8 playlists) and
// attaches SUBTITLES="subs" to every #EXT-X-STREAM-INF line so the player can
// select them. childBase is the absolute base URL for this session.
func injectSubtitleRenditions(master string, probe *ProbeResult, childBase string) string {
	if probe == nil || len(probe.Subtitles) == 0 {
		return master
	}

	var media strings.Builder
	for i, s := range probe.Subtitles {
		name := s.Title
		if name == "" {
			name = fmt.Sprintf("Subtitles %d", i+1)
		}
		lang := s.Language
		if lang == "" {
			lang = "und"
		}
		fmt.Fprintf(&media,
			"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"%s\",LANGUAGE=\"%s\",DEFAULT=NO,AUTOSELECT=NO,URI=\"%s/sub_%d.m3u8\"\n",
			escapeM3U8Attr(name), lang, childBase, i,
		)
	}

	lines := strings.Split(master, "\n")
	var out strings.Builder
	insertedMedia := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#EXT-X-STREAM-INF") {
			if !insertedMedia {
				out.WriteString(media.String())
				insertedMedia = true
			}
			if !strings.Contains(line, "SUBTITLES=") {
				line += ",SUBTITLES=\"subs\""
			}
		}
		out.WriteString(line)
		out.WriteString("\n")
	}

	// If no STREAM-INF was found (unexpected), append the media entries anyway.
	if !insertedMedia {
		out.WriteString(media.String())
	}
	return strings.TrimRight(out.String(), "\n") + "\n"
}

// escapeM3U8Attr escapes double quotes in an M3U8 attribute value.
func escapeM3U8Attr(s string) string {
	return strings.ReplaceAll(s, "\"", "'")
}
