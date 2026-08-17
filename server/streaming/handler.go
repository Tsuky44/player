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

// segmentDuration is the HLS target segment length in seconds.
//
// Time-to-first-playlist is proportional to it: FFmpeg cannot publish the
// variant playlist before the first segment is fully encoded. Measured 0.31s at
// 4s vs 0.16s at 2s on a fast host — on the CPU-only production box with a 4K
// HEVC source that difference is seconds of spinner, so 2s it is.
const segmentDuration = 2

// segmentWait is how long a request for a not-yet-written segment will wait for
// the transcoder to produce it before giving up.
//
// Deliberately longer than the couple of seconds a segment takes to encode:
// answering 503 hands the problem to the player's retry backoff, which costs
// far more than the wait it avoids — a segment that was 2s away can take much
// longer to be re-requested than to be produced. Holding the request open
// covers the normal case (the encoder is close behind and about to write it)
// while still giving up quickly enough on a target that is genuinely minutes
// away, which the client should have turned into a new session anyway.
const segmentWait = 12 * time.Second

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
	// AudioMap lists the source audio tracks published as renditions, in the
	// order the player will enumerate them. Position k in the player's audio
	// track list is source track AudioMap[k], which is how the client switches
	// language without asking for a new session.
	AudioMap []int `json:"audio_map"`
	// BurnedSubtitle echoes the bitmap subtitle stream rendered into the video,
	// or -1. The client compares it with what it asked for to know whether the
	// request was honoured.
	BurnedSubtitle int `json:"burned_subtitle"`
}

func (h *Handler) handleStart(w http.ResponseWriter, r *http.Request, mediaID int) {
	startedAt := time.Now()

	quality := r.URL.Query().Get("quality")
	if quality == "" {
		quality = "720p"
	}
	startSeconds := atoiDefault(r.URL.Query().Get("start"), 0)
	audioIndex := atoiDefault(r.URL.Query().Get("audio"), 0)
	burnSubtitle := atoiDefault(r.URL.Query().Get("burnsub"), NoBurnedSubtitle)

	inputPath, err := h.getMediaFilePath(mediaID)
	if err != nil {
		log.Printf("HLS start: media %d: %v", mediaID, err)
		http.Error(w, "media not found", http.StatusNotFound)
		return
	}

	// Prefer the probe persisted at index time. Re-running ffprobe here costs
	// 0.3–1s on network storage and is paid again on every quality switch,
	// audio switch and large seek — all of which restart the session.
	probe, ok := h.loadCachedProbe(mediaID, inputPath)
	if !ok {
		probe, err = ProbeTracks(inputPath)
		if err != nil {
			log.Printf("HLS start: probe failed for media %d: %v", mediaID, err)
			probe = &ProbeResult{}
		} else {
			h.persistProbe(mediaID, inputPath, probe)
		}
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

	audioMap := SelectAudioRenditions(probe, audioIndex)

	// Only a real bitmap stream may be burned in. A bogus index would make FFmpeg
	// fail to build its filter graph and the whole session would die, so an
	// unusable request degrades to no burn-in rather than to a broken stream.
	if burnSubtitle >= 0 && !isBurnableSubtitle(probe, burnSubtitle) {
		log.Printf("HLS start: media %d: subtitle 0:s:%d cannot be burned in, ignoring",
			mediaID, burnSubtitle)
		burnSubtitle = NoBurnedSubtitle
	}

	// Repackage the picture rather than re-encode it whenever that is safe: the
	// browser only ever needed a different container and a different audio codec,
	// not different frames.
	bitrate := h.sourceBitrate(mediaID)
	copyVideo := CanCopyVideo(probe, quality, burnSubtitle >= 0, bitrate, copyBitrateCeiling())

	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:              inputPath,
		Quality:                quality,
		StartSeconds:           startSeconds,
		TmpDir:                 tmpDir,
		Probe:                  probe,
		SegmentDuration:        segmentDuration,
		AudioTypedIndexes:      audioMap,
		BurnSubtitle:           burnSubtitle >= 0,
		BurnSubtitleTypedIndex: burnSubtitle,
		CopyVideo:              copyVideo,
	})

	// Copying the picture means the file's own bitrate goes out on the wire, so
	// that — not the preset's ceiling, which no encoder is enforcing here — is
	// what the variant has to be advertised at.
	advertisedBandwidth := EstimateBandwidth(quality)
	if copyVideo && bitrate > 0 {
		advertisedBandwidth = int(bitrate)
	}
	master := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:                  probe,
		Quality:                quality,
		AudioTypedIndexes:      audioMap,
		DefaultAudioTypedIndex: audioIndex,
		BandwidthBps:           advertisedBandwidth,
	})

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)

	sessionID := uuid.New().String()
	session := &TranscodeSession{
		ID:             sessionID,
		MediaID:        mediaID,
		Quality:        quality,
		AudioIndex:     audioIndex,
		StartOffset:    startSeconds,
		TmpDir:         tmpDir,
		Probe:          probe,
		MasterPlaylist: master,
		ctx:            ctx,
		cancel:         cancel,
		cmd:            cmd,
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
		SessionID:      sessionID,
		MasterURL:      fmt.Sprintf("%s/api/v1/stream/%d/%s/master.m3u8", baseURL, mediaID, sessionID),
		Duration:       probe.Duration,
		StartOffset:    startSeconds,
		Quality:        quality,
		AudioMap:       audioMap,
		BurnedSubtitle: burnSubtitle,
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_ = json.NewEncoder(w).Encode(resp)

	videoMode := "encode"
	if copyVideo {
		videoMode = "copy"
	}
	log.Printf("HLS: session %s media %d quality=%s video=%s (%.1f Mbps) start=%ds audio=%d renditions=%v burnsub=%d ready in %v",
		sessionID, mediaID, quality, videoMode, float64(bitrate)/1e6,
		startSeconds, audioIndex, audioMap, burnSubtitle,
		time.Since(startedAt))
}

// handleServeFile serves one playlist or segment of a session.
//
// The master is rendered here; everything below it comes straight off the
// session's temp dir. Child URIs stay relative in both, so a player resolves
// them against the master URL it fetched and no rewriting is needed on the way
// out.
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

	// The master is rendered from the session's own parameters, not read back from
	// the copy FFmpeg wrote — see BuildMasterPlaylist for why that file cannot be
	// served. Answering out of memory also means the master is ready the moment
	// the session exists, before FFmpeg has written anything at all.
	if filename == "master.m3u8" {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write([]byte(session.MasterPlaylist))
		return
	}

	filePath := filepath.Join(session.TmpDir, filename)
	ext := strings.ToLower(filepath.Ext(filename))

	// A segment listed in the playlist can legitimately not exist on disk yet:
	// the JIT throttler SIGSTOPs FFmpeg once it is far enough ahead, and resumes
	// it on the next tick. Answering 404 there is fatal for the HLS demuxer, so
	// wait briefly for the file, then ask the client to retry instead.
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		if ext == ".ts" && waitForPath(filePath, segmentWait) {
			// produced while we waited — fall through and serve it
		} else if ext == ".ts" {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "segment not ready", http.StatusServiceUnavailable)
			return
		} else {
			http.Error(w, "file not ready", http.StatusNotFound)
			return
		}
	}

	switch ext {
	case ".ts":
		w.Header().Set("Content-Type", "video/mp2t")
		// Segments are immutable for the lifetime of the session: name them once,
		// never rewrite them. Revalidating each one costs a round-trip per 2s of
		// video, which matters most on the re-reads a seek triggers.
		w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	case ".m3u8":
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		// The variant playlist grows as segments land — never cache it.
		w.Header().Set("Cache-Control", "no-cache")
	case ".vtt":
		w.Header().Set("Content-Type", "text/vtt")
		w.Header().Set("Cache-Control", "private, max-age=3600")
	default:
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "no-cache")
	}
	http.ServeFile(w, r, filePath)
}

// waitForPath polls for a file to appear, returning true if it did in time.
func waitForPath(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

// loadCachedProbe returns the probe persisted by the indexer, provided the file
// has not changed on disk since. Mirrors indexer.LoadCachedProbe, which cannot
// be imported here (indexer already depends on this package).
func (h *Handler) loadCachedProbe(mediaID int, filePath string) (*ProbeResult, bool) {
	var tracksJSON sql.NullString
	var storedModTime sql.NullInt64
	err := h.db.QueryRow(
		"SELECT tracks_json, file_mod_time FROM medias WHERE id = ?",
		mediaID,
	).Scan(&tracksJSON, &storedModTime)
	if err != nil || !tracksJSON.Valid || tracksJSON.String == "" {
		return nil, false
	}

	info, err := os.Stat(filePath)
	if err != nil {
		return nil, false
	}
	if storedModTime.Valid && storedModTime.Int64 != info.ModTime().Unix() {
		return nil, false
	}

	probe, err := UnmarshalProbeResult(tracksJSON.String)
	if err != nil {
		return nil, false
	}
	// Entries written before PixFmt existed carry no pixel format, and the copy
	// decision cannot tell 8-bit H.264 from High 10 without it — so it refuses,
	// and an entire pre-existing library stays on the encoding path forever.
	// Treat those as a miss so they are re-probed once and rewritten.
	if probe.Video != nil && probe.Video.PixFmt == "" {
		return nil, false
	}
	return probe, true
}

// persistProbe rewrites the cached probe after a live one, so a media whose
// entry was stale costs one ffprobe in total rather than one per session start.
//
// Deliberately narrow: it touches tracks_json and the mod-time stamp that
// validates it, and leaves every other column to the indexer.
func (h *Handler) persistProbe(mediaID int, filePath string, probe *ProbeResult) {
	tracksJSON, err := MarshalProbeResult(probe)
	if err != nil {
		return
	}
	var modTime int64
	if info, statErr := os.Stat(filePath); statErr == nil {
		modTime = info.ModTime().Unix()
	}
	if _, err := h.db.Exec(
		"UPDATE medias SET tracks_json = ?, file_mod_time = ?, probed_at = CURRENT_TIMESTAMP WHERE id = ?",
		tracksJSON, modTime, mediaID,
	); err != nil {
		log.Printf("HLS: failed to persist refreshed probe for media %d: %v", mediaID, err)
	}
}

// defaultCopyBitrateCeiling caps what the server will push out untouched.
//
// Copying the picture means sending the file's own bitrate, with no ceiling of
// its own — a Blu-ray remux at 30 Mbps would leave the CPU idle and stall the
// viewer instead. 12 Mbps clears ordinary 1080p rips (3–10 Mbps) while keeping
// remuxes on the transcoding path. Override with COPY_BITRATE_CEILING_MBPS; 0
// disables the ceiling entirely.
const defaultCopyBitrateCeiling = 12_000_000

func copyBitrateCeiling() int64 {
	raw := strings.TrimSpace(os.Getenv("COPY_BITRATE_CEILING_MBPS"))
	if raw == "" {
		return defaultCopyBitrateCeiling
	}
	mbps, err := strconv.ParseFloat(raw, 64)
	if err != nil || mbps < 0 {
		log.Printf("HLS: invalid COPY_BITRATE_CEILING_MBPS %q, using default", raw)
		return defaultCopyBitrateCeiling
	}
	return int64(mbps * 1_000_000)
}

// sourceBitrate estimates the file's overall bitrate in bits per second from
// what the indexer already stores, so no extra probe is needed.
//
// It counts audio and subtitles along with the picture, which overstates the
// video slightly — an error in the safe direction: it can only push a borderline
// file onto the transcoding path, never the reverse.
func (h *Handler) sourceBitrate(mediaID int) int64 {
	var fileSize sql.NullInt64
	var duration sql.NullInt64
	err := h.db.QueryRow(
		"SELECT file_size, duration FROM medias WHERE id = ?", mediaID,
	).Scan(&fileSize, &duration)
	if err != nil || !fileSize.Valid || !duration.Valid ||
		fileSize.Int64 <= 0 || duration.Int64 <= 0 {
		return 0 // unknown — treated as "no ceiling breach"
	}
	return fileSize.Int64 * 8 / duration.Int64
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

// isBurnableSubtitle reports whether 0:s:index is a bitmap subtitle stream.
// Text subtitles are never burned in: they are served out of band as WebVTT,
// which stays toggleable without touching the transcode.
func isBurnableSubtitle(probe *ProbeResult, index int) bool {
	if probe == nil {
		return false
	}
	for _, s := range probe.Subtitles {
		if s.TypedIndex == index {
			return s.Image
		}
	}
	return false
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
