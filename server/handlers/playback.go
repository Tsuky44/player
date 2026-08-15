package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
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
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	var introStart, introEnd, outroStart, outroEnd, seasonID, duration int
	err = database.DB.QueryRow(
		"SELECT intro_start, intro_end, outro_start, outro_end, parent_id, COALESCE(duration, 0) FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&introStart, &introEnd, &outroStart, &outroEnd, &seasonID, &duration)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("Timestamps error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	// If timestamps are empty, trigger background detection
	if introEnd == 0 && outroStart == 0 && seasonID > 0 {
		go func(sID int) {
			log.Printf("Timestamps: Triggering background detection for season %d (episode %d)", sID, episodeID)
			if err := indexer.AnalyzeSeason(sID); err != nil {
				log.Printf("Timestamps: Background detection failed for season %d: %v", sID, err)
			}
		}(seasonID)
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
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	// Fetch file path of the episode
	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ? AND type = 'episode'", episodeID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("GetEpisodeChapters DB error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	if filePath == "" {
		http.Error(w, `{"error": "Media file path is empty"}`, http.StatusBadRequest)
		return
	}

	// Spawn ffprobe
	cmd := exec.Command("ffprobe", "-v", "quiet", "-print_format", "json", "-show_chapters", filePath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err = cmd.Run()
	if err != nil {
		log.Printf("ffprobe execution failed: %v, stderr: %s", err, stderr.String())
		// Return empty list instead of 500 so client doesn't crash
		json.NewEncoder(w).Encode(map[string]interface{}{"chapters": []interface{}{}})
		return
	}

	// Parse JSON output
	var ffResponse struct {
		Chapters []struct {
			ID        int                    `json:"id"`
			StartTime string                 `json:"start_time"`
			EndTime   string                 `json:"end_time"`
			Tags      map[string]interface{} `json:"tags"`
		} `json:"chapters"`
	}

	if err := json.Unmarshal(stdout.Bytes(), &ffResponse); err != nil {
		log.Printf("Failed to unmarshal ffprobe output: %v", err)
		json.NewEncoder(w).Encode(map[string]interface{}{"chapters": []interface{}{}})
		return
	}

	// Map to simplified schema compatible with client structure
	type ChapterItem struct {
		ID        int     `json:"id"`
		StartTime float64 `json:"start_time"`
		EndTime   float64 `json:"end_time"`
		Title     string  `json:"title"`
	}

	chapters := make([]ChapterItem, 0)
	for _, c := range ffResponse.Chapters {
		start, _ := strconv.ParseFloat(c.StartTime, 64)
		end, _ := strconv.ParseFloat(c.EndTime, 64)

		title := fmt.Sprintf("Chapter %d", c.ID)
		if c.Tags != nil {
			if t, ok := c.Tags["title"]; ok {
				title = fmt.Sprintf("%v", t)
			} else if t, ok := c.Tags["TITLE"]; ok {
				title = fmt.Sprintf("%v", t)
			}
		}

		chapters = append(chapters, ChapterItem{
			ID:        c.ID,
			StartTime: start,
			EndTime:   end,
			Title:     title,
		})
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
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	var filePath string
	err = database.DB.QueryRow("SELECT file_path FROM medias WHERE id = ?", mediaID).Scan(&filePath)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		} else {
			log.Printf("GetMediaTracks DB error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	if filePath == "" {
		http.Error(w, `{"error": "Media file path is empty"}`, http.StatusBadRequest)
		return
	}

	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		http.Error(w, `{"error": "Media file not found on disk"}`, http.StatusNotFound)
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
			http.Error(w, `{"error": "Failed to probe media tracks"}`, http.StatusInternalServerError)
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

	json.NewEncoder(w).Encode(map[string]interface{}{
		"video":     probe.Video,
		"audio":     probe.Audio,
		"subtitles": subs,
	})
}
