package indexer

import (
	"database/sql"
	"log"
	"math"
	"os"
	"sync/atomic"
	"time"

	"project-player/server/database"
	"project-player/server/streamcache"
	"project-player/server/streaming"
)

// probingBackfill is read by the scan-status endpoint while the backfill
// goroutine writes it — see the note on indexer.scanning.
var probingBackfill atomic.Bool

// IsProbingBackfill reports whether an ffprobe backfill is currently running.
func IsProbingBackfill() bool { return probingBackfill.Load() }

// ProbeAndPersist runs ffprobe once and stores tracks/duration metadata in the DB.
func ProbeAndPersist(mediaID int, title, filePath string, fileSize int64, modTime time.Time) {
	probe, err := streaming.ProbeTracks(filePath)
	if err != nil {
		log.Printf("Indexer: probe failed for media %d (%s): %v", mediaID, title, err)
		return
	}

	tracksJSON, err := streaming.MarshalProbeResult(probe)
	if err != nil {
		log.Printf("Indexer: marshal probe failed for media %d: %v", mediaID, err)
		return
	}

	durationSec := int(math.Round(probe.Duration))
	analysis := streaming.AnalyzeStreamingFile(filePath)
	streaming.LogAnalysis(mediaID, title, filePath, analysis)

	_, err = database.DB.Exec(`
		UPDATE medias SET
			file_size = ?,
			tracks_json = ?,
			probed_at = CURRENT_TIMESTAMP,
			file_mod_time = ?,
			duration = CASE WHEN ? > 0 THEN ? ELSE duration END,
			gop_seconds = ?
		WHERE id = ?`,
		fileSize,
		tracksJSON,
		modTime.Unix(),
		durationSec, durationSec,
		nullFloat(analysis.GOPSeconds),
		mediaID,
	)
	if err != nil {
		log.Printf("Indexer: failed to persist probe for media %d: %v", mediaID, err)
		return
	}

	streamcache.Global().Invalidate(mediaID)
}

func nullFloat(v float64) interface{} {
	if v <= 0 {
		return nil
	}
	return v
}

// BackfillMissingProbesAsync probes indexed movies/episodes that lack tracks_json.
// Returns false when a backfill is already running.
func BackfillMissingProbesAsync() bool {
	if !probingBackfill.CompareAndSwap(false, true) {
		log.Println("Indexer: Probe backfill already in progress.")
		return false
	}

	go func() {
		defer probingBackfill.Store(false)

		rows, err := database.DB.Query(`
			SELECT id, title, file_path, COALESCE(file_size, 0)
			FROM medias
			WHERE type IN ('movie', 'episode')
			  AND file_path IS NOT NULL AND file_path != ''
			  AND (tracks_json IS NULL OR tracks_json = '')`)
		if err != nil {
			log.Printf("Indexer: probe backfill query failed: %v", err)
			return
		}
		defer rows.Close()

		count := 0
		for rows.Next() {
			var id int
			var title, path string
			var size int64
			if err := rows.Scan(&id, &title, &path, &size); err != nil {
				log.Printf("Indexer: probe backfill scan failed: %v", err)
				continue
			}
			info, err := os.Stat(path)
			if err != nil {
				continue
			}
			if size == 0 {
				size = info.Size()
			}
			ProbeAndPersist(id, title, path, size, info.ModTime())
			count++
		}
		log.Printf("Indexer: Probe backfill completed (%d files)", count)
	}()

	return true
}

// InvalidateStreamCaches clears in-memory stream metadata after a library scan.
func InvalidateStreamCaches() {
	streamcache.Global().Clear()
}

// LoadCachedProbe returns a stored probe if the file has not changed on disk.
func LoadCachedProbe(mediaID int, filePath string) (*streaming.ProbeResult, bool) {
	var tracksJSON sql.NullString
	var storedModTime sql.NullInt64
	err := database.DB.QueryRow(
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

	probe, err := streaming.UnmarshalProbeResult(tracksJSON.String)
	if err != nil {
		return nil, false
	}
	// Same rule as streaming.Handler.loadCachedProbe: an entry predating PixFmt
	// cannot answer the copy-or-encode question, so it is re-probed rather than
	// trusted. Kept in sync deliberately — the two caches must not disagree on
	// what counts as usable.
	if probe.Video != nil && probe.Video.PixFmt == "" {
		return nil, false
	}
	return probe, true
}

// PersistProbeAfterLiveProbe stores a freshly probed result (GetMediaTracks fallback).
func PersistProbeAfterLiveProbe(mediaID int, filePath string, probe *streaming.ProbeResult) {
	tracksJSON, err := streaming.MarshalProbeResult(probe)
	if err != nil {
		return
	}
	info, err := os.Stat(filePath)
	if err != nil {
		return
	}
	durationSec := int(math.Round(probe.Duration))
	analysis := streaming.AnalyzeStreamingFile(filePath)
	streaming.LogAnalysis(mediaID, "", filePath, analysis)

	_, _ = database.DB.Exec(`
		UPDATE medias SET
			file_size = ?,
			tracks_json = ?,
			probed_at = CURRENT_TIMESTAMP,
			file_mod_time = ?,
			duration = CASE WHEN ? > 0 THEN ? ELSE duration END,
			gop_seconds = ?
		WHERE id = ?`,
		info.Size(),
		tracksJSON,
		info.ModTime().Unix(),
		durationSec, durationSec,
		nullFloat(analysis.GOPSeconds),
		mediaID,
	)
	streamcache.Global().Invalidate(mediaID)
}
