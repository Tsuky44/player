package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"

	"project-player/server/database"
	"project-player/server/indexer"

	"github.com/julienschmidt/httprouter"
)

var serverStartedAt = time.Now()

// ActiveTranscodes reports the HLS sessions running right now. Wired by main to
// the streaming handler, which lives in a package this one cannot import.
var ActiveTranscodes = func() int { return 0 }

// ServerInfo is the dashboard's picture of the server itself.
type ServerInfo struct {
	StartedAt     time.Time `json:"started_at"`
	UptimeSeconds int64     `json:"uptime_seconds"`
	GoVersion     string    `json:"go_version"`
	OS            string    `json:"os"`
	Arch          string    `json:"arch"`
	CPUs          int       `json:"cpus"`
	MemoryBytes   uint64    `json:"memory_bytes"`
	DatabaseBytes int64     `json:"database_bytes"`
	Transcodes    int       `json:"transcodes"`
	NowPlaying    int       `json:"now_playing"`
	Users         int       `json:"users"`
	ActiveDevices int       `json:"active_devices"`
	Scanning      bool      `json:"scanning"`
	Library       struct {
		Movies          int   `json:"movies"`
		Shows           int   `json:"shows"`
		Episodes        int   `json:"episodes"`
		TotalBytes      int64 `json:"total_bytes"`
		DurationSeconds int64 `json:"duration_seconds"`
	} `json:"library"`
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

// GetServerInfo answers GET /api/admin/server (any administration right).
func GetServerInfo(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, _ int) {
	var info ServerInfo
	info.StartedAt = serverStartedAt.UTC()
	info.UptimeSeconds = int64(time.Since(serverStartedAt).Seconds())
	info.GoVersion = runtime.Version()
	info.OS = runtime.GOOS
	info.Arch = runtime.GOARCH
	info.CPUs = runtime.NumCPU()
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	info.MemoryBytes = mem.Sys
	if database.Path != "" {
		info.DatabaseBytes = fileSize(database.Path) + fileSize(database.Path+"-wal")
	}
	info.Transcodes = ActiveTranscodes()
	info.NowPlaying = playbackActivity.count()
	info.Scanning = indexer.IsScanning()

	_ = database.DB.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&info.Users)
	_ = database.DB.QueryRow(
		`SELECT COUNT(*) FROM sessions WHERE COALESCE(last_seen_at, created_at) > datetime('now', '-1 days')`,
	).Scan(&info.ActiveDevices)

	rows, err := database.DB.Query(`
		SELECT type, COUNT(*), COALESCE(SUM(file_size), 0), COALESCE(SUM(duration), 0)
		FROM medias WHERE type IN ('movie', 'show', 'episode') GROUP BY type`)
	if err != nil {
		log.Printf("GetServerInfo: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var kind string
		var count int
		var size, duration int64
		if err := rows.Scan(&kind, &count, &size, &duration); err != nil {
			log.Printf("GetServerInfo: %v", err)
			continue
		}
		switch kind {
		case "movie":
			info.Library.Movies = count
		case "show":
			info.Library.Shows = count
		case "episode":
			info.Library.Episodes = count
		}
		if kind != "show" {
			info.Library.TotalBytes += size
			info.Library.DurationSeconds += duration
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(info)
}
