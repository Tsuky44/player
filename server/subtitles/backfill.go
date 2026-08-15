package subtitles

import (
	"database/sql"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"project-player/server/database"
)

// extracting is read by the scan-status endpoint while the extraction
// goroutine writes it, so it is atomic rather than a plain bool guarded only on
// the write side. extractMutex still protects the progress counters.
var extracting atomic.Bool

// IsExtracting reports whether a library-wide forced subtitle extraction runs.
func IsExtracting() bool { return extracting.Load() }

var (
	extractMutex sync.Mutex
	extractStats ExtractStats
)

// ExtractStats holds progress for the current or last batch extraction run.
type ExtractStats struct {
	Total     int `json:"total"`
	Processed int `json:"processed"`
	Succeeded int `json:"succeeded"`
	Failed    int `json:"failed"`
	Tracks    int `json:"tracks"`
}

// LastExtractStats returns a snapshot of the latest batch run.
func LastExtractStats() ExtractStats {
	extractMutex.Lock()
	defer extractMutex.Unlock()
	return extractStats
}

// TryStartForceExtractAll launches a background re-extraction for every movie
// and episode. Returns false if a run is already in progress.
func TryStartForceExtractAll() bool {
	if !extracting.CompareAndSwap(false, true) {
		return false
	}
	extractMutex.Lock()
	extractStats = ExtractStats{}
	extractMutex.Unlock()

	go runForceExtractAll()
	return true
}

func runForceExtractAll() {
	defer extracting.Store(false)

	started := time.Now()
	log.Println("subtitles: starting forced library extraction…")

	rows, err := database.DB.Query(
		`SELECT id, file_path FROM medias
		 WHERE type IN ('movie', 'episode')
		   AND file_path IS NOT NULL AND file_path != ''
		 ORDER BY id`,
	)
	if err != nil {
		log.Printf("subtitles: library extract query failed: %v", err)
		return
	}
	defer rows.Close()

	type item struct {
		id       int
		filePath string
	}
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.filePath); err != nil {
			continue
		}
		items = append(items, it)
	}

	extractMutex.Lock()
	extractStats.Total = len(items)
	extractMutex.Unlock()

	for _, it := range items {
		n, err := ForceExtractAndRegister(it.id, it.filePath)
		extractMutex.Lock()
		extractStats.Processed++
		if err != nil {
			extractStats.Failed++
			log.Printf("subtitles: force extract media %d failed: %v", it.id, err)
		} else {
			extractStats.Succeeded++
			extractStats.Tracks += n
		}
		extractMutex.Unlock()
	}

	extractMutex.Lock()
	stats := extractStats
	extractMutex.Unlock()
	log.Printf("subtitles: library extraction done in %v — %d/%d ok, %d tracks, %d failed",
		time.Since(started), stats.Succeeded, stats.Total, stats.Tracks, stats.Failed)
}

// MediaFilePath looks up the on-disk path for a playable media row.
func MediaFilePath(mediaID int) (string, error) {
	var filePath sql.NullString
	err := database.DB.QueryRow(
		`SELECT file_path FROM medias WHERE id = ? AND type IN ('movie', 'episode')`,
		mediaID,
	).Scan(&filePath)
	if err != nil {
		return "", err
	}
	if !filePath.Valid || filePath.String == "" {
		return "", sql.ErrNoRows
	}
	return filePath.String, nil
}
