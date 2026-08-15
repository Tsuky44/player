package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/subtitles"

	"github.com/julienschmidt/httprouter"
)

// DebugIntroOutro returns all episodes with intro/outro data for debugging
func DebugIntroOutro(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	type EpisodeDebug struct {
		ID         int    `json:"id"`
		Title      string `json:"title"`
		IntroStart int    `json:"intro_start"`
		IntroEnd   int    `json:"intro_end"`
		OutroStart int    `json:"outro_start"`
		OutroEnd   int    `json:"outro_end"`
	}

	episodes := []EpisodeDebug{}

	query := `
		SELECT id, title, intro_start, intro_end, outro_start, outro_end
		FROM medias
		WHERE type = 'episode'
		ORDER BY id DESC
		LIMIT 20
	`

	rows, err := database.DB.Query(query)
	if err != nil {
		log.Printf("DebugIntroOutro error: %v", err)
		http.Error(w, `{"error": "Database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var ep EpisodeDebug
		err := rows.Scan(&ep.ID, &ep.Title, &ep.IntroStart, &ep.IntroEnd, &ep.OutroStart, &ep.OutroEnd)
		if err != nil {
			log.Printf("DebugIntroOutro scan error: %v", err)
			continue
		}
		episodes = append(episodes, ep)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"count":    len(episodes),
		"episodes": episodes,
	})
}

// DetectShowIntroOutro triggers intro/outro detection for a specific show
func DetectShowIntroOutro(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	// Get show ID from URL parameter
	showIDStr := ps.ByName("id")
	showID, err := strconv.Atoi(showIDStr)
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}

	// Run detection
	results, err := indexer.DetectIntrosOutrosForShow(showID)
	if err != nil {
		log.Printf("DetectShowIntroOutro error: %v", err)
		http.Error(w, fmt.Sprintf(`{"error": "%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"show_id": showID,
		"seasons": results,
		"message": "Detection completed successfully",
	})
}

// TriggerScan starts a new background media scan (POST /api/indexer/scan)
func TriggerScan(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	moviesDir := config.MoviesDir()
	seriesDir := config.SeriesDir()

	// ScanMedia claims the run atomically, so two simultaneous triggers cannot
	// both believe they started one.
	if !indexer.ScanMedia(moviesDir, seriesDir) {
		http.Error(w, `{"error": "Scan is already in progress"}`, http.StatusConflict)
		return
	}

	w.Write([]byte(`{"status": "success", "message": "Scan triggered in background"}`))
}

// TriggerShowDedupe merges duplicate TV show and movie rows (POST /api/indexer/dedupe).
func TriggerShowDedupe(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	go func() {
		indexer.DedupeDuplicateShows()
		indexer.DedupeDuplicateMovies()
	}()
	w.Write([]byte(`{"status": "success", "message": "Deduplication started in background"}`))
}

// TriggerMetadataBackfill fetches missing TMDB posters without re-scanning files.
func TriggerMetadataBackfill(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	if !indexer.BackfillMissingMetadataAsync() {
		http.Error(w, `{"error": "Metadata backfill is already in progress"}`, http.StatusConflict)
		return
	}

	w.Write([]byte(`{"status": "success", "message": "Metadata backfill started in background"}`))
}

// TriggerRedetectAll re-runs TMDB identification for every movie and show
// (POST /api/indexer/metadata/redetect-all).
func TriggerRedetectAll(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	if !indexer.RedetectAllMediaAsync() {
		http.Error(w, `{"error": "Bulk redetect is already in progress"}`, http.StatusConflict)
		return
	}

	w.Write([]byte(`{"status": "success", "message": "Bulk metadata redetect started in background"}`))
}

// TriggerProbeBackfill runs ffprobe on indexed files missing tracks_json.
func TriggerProbeBackfill(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	if !indexer.BackfillMissingProbesAsync() {
		http.Error(w, `{"error": "Probe backfill is already in progress"}`, http.StatusConflict)
		return
	}

	w.Write([]byte(`{"status": "success", "message": "Probe backfill started in background"}`))
}

// GetScanStatus returns the current status of the indexer (GET /api/indexer/status)
func GetScanStatus(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"is_scanning":             indexer.IsScanning(),
		"is_backfilling_metadata": indexer.IsBackfilling(),
		"is_redetecting_all":      indexer.IsRedetectingAll(),
		"redetect_all":            indexer.RedetectAllProgressSnapshot(),
		"is_extracting_subtitles": subtitles.IsExtracting(),
		"subtitle_extraction":     subtitles.LastExtractStats(),
		"last_scan":               indexer.LastScanReport(),
	})
}

// GetScanReport details the last scan: files seen, indexed, skipped (with the
// reason) and items left without a TMDB match (GET /api/indexer/report). This is
// what explains a gap between the number of files on disk and the library count.
func GetScanReport(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(indexer.LastScanReport())
}
