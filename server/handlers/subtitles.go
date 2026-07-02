package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"

	"project-player/server/subtitles"

	"github.com/julienschmidt/httprouter"
)

// GetMediaSubtitle serves a pre-extracted external subtitle as WebVTT:
//
//	GET /api/v1/media/:id/subtitles/:file   (e.g. fr.vtt) [?start=SECONDS]
//	GET /api/v1/media/:id/subtitles?lang=fr [?start=SECONDS]   (legacy)
//
// The path form ending in ".vtt" is preferred because libmpv/media_kit picks
// the subtitle parser from the URL extension — without it the track silently
// fails to load. It reads the .vtt file registered at scan time. `start`
// rebases the cues to match an HLS stream that begins at an offset (Direct Play
// uses 0). The route is unauthenticated so media_kit/mpv can fetch it directly.
func GetMediaSubtitle(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Authorization")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, "invalid media id", http.StatusBadRequest)
		return
	}

	// Language comes from the path (".../subtitles/fr.vtt") or, for the legacy
	// form, the ?lang= query parameter.
	lang := strings.TrimSuffix(ps.ByName("file"), ".vtt")
	if lang == "" {
		lang = r.URL.Query().Get("lang")
	}
	if lang == "" {
		http.Error(w, "lang is required", http.StatusBadRequest)
		return
	}
	start := 0
	if v, e := strconv.Atoi(r.URL.Query().Get("start")); e == nil && v > 0 {
		start = v
	}

	path, err := subtitles.Path(mediaID, lang)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, "subtitle not found", http.StatusNotFound)
		} else {
			log.Printf("GetMediaSubtitle lookup %d/%s: %v", mediaID, lang, err)
			http.Error(w, "subtitle error", http.StatusInternalServerError)
		}
		return
	}

	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("GetMediaSubtitle read %s: %v", path, err)
		http.Error(w, "subtitle file missing", http.StatusNotFound)
		return
	}
	if start > 0 {
		data = subtitles.ShiftVTT(data, start)
	}

	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(data)
}

// TriggerSubtitleExtract starts a forced subtitle re-extraction for the entire
// library in the background (POST /api/indexer/subtitles/extract).
func TriggerSubtitleExtract(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	if !subtitles.TryStartForceExtractAll() {
		http.Error(w, `{"error": "Subtitle extraction is already in progress"}`, http.StatusConflict)
		return
	}

	w.Write([]byte(`{"status":"success","message":"Subtitle extraction triggered in background"}`))
}

// ForceMediaSubtitleExtract extracts subtitles for a single media item
// (POST /api/media/:id/subtitles/extract[?force=false]).
//
// By default it re-extracts everything (used by the manual "Extract" button).
// With ?force=false it only extracts when nothing is registered yet — this is
// the cheap "ensure" path the player calls in the background on playback start.
func ForceMediaSubtitleExtract(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	filePath, err := subtitles.MediaFilePath(mediaID)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Media not found or has no file"}`, http.StatusNotFound)
		} else {
			http.Error(w, `{"error": "Database error"}`, http.StatusInternalServerError)
		}
		return
	}
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		http.Error(w, `{"error": "Media file not found on disk"}`, http.StatusNotFound)
		return
	}

	force := r.URL.Query().Get("force") != "false"
	var count int
	if force {
		count, err = subtitles.ForceExtractAndRegister(mediaID, filePath)
	} else {
		count, err = subtitles.EnsureExtractedSync(mediaID, filePath)
	}
	if err != nil {
		log.Printf("ForceMediaSubtitleExtract %d: %v", mediaID, err)
		http.Error(w, `{"error": "Subtitle extraction failed"}`, http.StatusInternalServerError)
		return
	}

	tracks, _ := subtitles.List(mediaID)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "success",
		"media_id": mediaID,
		"tracks":   count,
		"subtitles": tracks,
	})
}
