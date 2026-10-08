package streaming

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
)

// Ce que le gestionnaire de sessions lit de la base sur un média : la sonde
// gardée par l'indexeur, le débit du fichier et son chemin.

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
	// An entry written by an older build carries fewer fields than the
	// copy-or-encode decision now reads, and a missing field is
	// indistinguishable from a "no" — so it is re-probed once and rewritten
	// rather than trusted. See probeVersion.
	if !probe.Current() {
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
