package handlers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/streaming"
	"project-player/server/subtitles"

	"github.com/julienschmidt/httprouter"
)

// GetEpisodeTimestamps returns the intro/outro timestamps for an episode (GET /api/episodes/:id/timestamps)
func GetEpisodeTimestamps(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid episode ID")
		return
	}

	var introStart, introEnd, outroStart, outroEnd, seasonID, duration int
	err = database.DB.QueryRow(
		"SELECT intro_start, intro_end, outro_start, outro_end, parent_id, COALESCE(duration, 0) FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&introStart, &introEnd, &outroStart, &outroEnd, &seasonID, &duration)
	if err != nil {
		if err == sql.ErrNoRows {
			writeJSONError(w, http.StatusNotFound, "Episode not found")
		} else {
			log.Printf("Timestamps error: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		}
		return
	}

	// If timestamps are empty, trigger background detection
	if introEnd == 0 && outroStart == 0 && seasonID > 0 {
		indexer.RequestSeasonAnalysis(seasonID)
	}

	// Drop corrupt intro markers (e.g. a false-positive chapter spanning to EOF).
	if !indexer.IsPlausibleIntroRange(introStart, introEnd, duration) {
		introStart, introEnd = 0, 0
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"media_id":    episodeID,
		"intro_start": introStart,
		"intro_end":   introEnd,
		"outro_start": outroStart,
		"outro_end":   outroEnd,
	})
}

// GetEpisodeChapters returns chapters dynamically parsed using ffprobe (GET /api/episodes/:id/chapters)
func GetEpisodeChapters(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid episode ID")
		return
	}

	// Fetch file path of the episode
	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ? AND type = 'episode'", episodeID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			writeJSONError(w, http.StatusNotFound, "Episode not found")
		} else {
			log.Printf("GetEpisodeChapters DB error: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		}
		return
	}

	if filePath == "" {
		writeJSONError(w, http.StatusBadRequest, "Media file path is empty")
		return
	}

	chapters, err := streaming.ProbeChapters(filePath)
	if err != nil {
		log.Printf("GetEpisodeChapters %d: %v", episodeID, err)
		// Return empty list instead of 500 so client doesn't crash
		chapters = nil
	}
	for i := range chapters {
		if chapters[i].Title == "" {
			chapters[i].Title = fmt.Sprintf("Chapter %d", chapters[i].ID)
		}
	}
	if chapters == nil {
		chapters = []streaming.Chapter{}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{
		"chapters": chapters,
	})
}

// GetMediaTracks returns the audio and subtitle tracks of a media file as
// detected by ffprobe. This lets the client display consistent track names
// in both direct play and transcoding modes.
func GetMediaTracks(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}

	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ?", mediaID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			writeJSONError(w, http.StatusNotFound, "Media not found")
		} else {
			log.Printf("GetMediaTracks DB error: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		}
		return
	}

	if filePath == "" {
		writeJSONError(w, http.StatusBadRequest, "Media file path is empty")
		return
	}

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		writeJSONError(w, http.StatusNotFound, "Media file not found on disk")
		return
	}

	var probe *streaming.ProbeResult
	if cached, ok := indexer.LoadCachedProbe(mediaID, filePath); ok {
		probe = cached
	} else {
		var err error
		probe, err = streaming.ProbeTracks(filePath)
		if err != nil {
			log.Printf("GetMediaTracks probe error for media %d: %v", mediaID, err)
			writeJSONError(w, http.StatusInternalServerError, "Failed to probe media tracks")
			return
		}
		go indexer.PersistProbeAfterLiveProbe(mediaID, filePath, probe)
	}

	// Audio comes from the file (ffprobe). Subtitles merge ffprobe discovery
	// (always visible in the UI) with DB registration (ready=true when extracted).
	// Extraction itself stays async — this endpoint must remain fast.
	subs := []interface{}{}
	for _, t := range subtitles.Catalog(mediaID, probe) {
		subs = append(subs, t)
	}

	// The transcoding ladder travels with the track list because that is what
	// the quality menu is built from, and it is fetched before playback starts —
	// the menu has to be right the first time it is opened, not after a session
	// exists. It is per-media so the rungs above the source can be left out.
	sourceHeight := 0
	if probe.Video != nil {
		sourceHeight = probe.Video.Height
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"video":     probe.Video,
		"audio":     probe.Audio,
		"subtitles": subs,
		"qualities": streaming.QualityLadderFor(sourceHeight),
	})
}
