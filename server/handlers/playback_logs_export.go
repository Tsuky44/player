package handlers

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
)

// L'export des journaux de lecture, en un fichier ZIP.
//
// Relire un journal depuis l'écran convient pour une panne ; en comparer dix,
// ou les confier à quelqu'un qui n'a pas de compte administrateur, demande un
// fichier. Chaque lecture ayant un journal devient un fichier texte, nommé pour
// qu'on sache de quoi il parle sans l'ouvrir. Le contenu reprend celui du
// bouton « Copier » de l'écran de journal : collé ou rangé, il se lit pareil.

const (
	// Le nom d'un fichier de l'archive reste lisible dans un explorateur : le
	// titre est tronqué, jamais le reste.
	exportTitleMaxRunes   = 50
	exportAccountMaxRunes = 30
	// Plafond de lectures par archive. La table des journaux est bornée, mais
	// ce plafond-ci ne dépend pas de la rétention qu'on lui donnera demain.
	exportMaxEntries = 500
)

// exportedLog is one play with its log, as the archive needs it.
type exportedLog struct {
	historyID  int64
	username   string
	title      string
	subtitle   string
	showTitle  string
	deviceName string
	client     string
	playMethod string
	startedAt  time.Time
	stats      string
	lines      []PlaybackLogLine
}

// ExportPlaybackLogs returns every play's log as a ZIP
// (GET /api/admin/playback-logs.zip, manage_users).
//
// Filtres, tous facultatifs : `user_id`, `history_id`, `from` et `to` (une date
// `2026-10-30` ou un instant RFC 3339 ; `to` en date inclut la journée),
// `tz_offset` (minutes à l'est d'UTC, pour les dates et les noms de fichier).
//
// La route ne se range pas sous `/api/admin/history/` : `:id` y occupe déjà le
// segment, et le routeur refuse une route statique à la même place.
func ExportPlaybackLogs(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	q := r.URL.Query()
	zone := time.FixedZone("client", queryInt(r, "tz_offset", 0, -14*60, 14*60)*60)

	query := `
		SELECT h.id, COALESCE(u.username, ''), h.title, h.subtitle, h.show_title,
		       h.device_name, h.client, h.play_method, CAST(h.started_at AS TEXT),
		       COALESCE(l.stats, ''), l.body
		FROM playback_logs l
		JOIN playback_history h ON h.id = l.history_id
		LEFT JOIN users u ON u.id = h.user_id
		WHERE 1 = 1`
	var args []any

	if id, err := strconv.ParseInt(q.Get("history_id"), 10, 64); err == nil && id > 0 {
		query += ` AND h.id = ?`
		args = append(args, id)
	}
	if id := queryInt(r, "user_id", 0, 0, 1<<31-1); id > 0 {
		query += ` AND h.user_id = ?`
		args = append(args, id)
	}
	if raw := q.Get("from"); raw != "" {
		from, _, ok := parseExportBound(raw, zone)
		if !ok {
			writeJSONError(w, http.StatusBadRequest, "Invalid from")
			return
		}
		query += ` AND h.started_at >= ?`
		args = append(args, historyStamp(from))
	}
	if raw := q.Get("to"); raw != "" {
		to, dateOnly, ok := parseExportBound(raw, zone)
		if !ok {
			writeJSONError(w, http.StatusBadRequest, "Invalid to")
			return
		}
		if dateOnly {
			to = to.AddDate(0, 0, 1)
		}
		query += ` AND h.started_at < ?`
		args = append(args, historyStamp(to))
	}
	query += ` ORDER BY h.id DESC LIMIT ?`
	args = append(args, exportMaxEntries)

	rows, err := database.DB.Query(query, args...)
	if err != nil {
		log.Printf("ExportPlaybackLogs: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	var logs []exportedLog
	for rows.Next() {
		var e exportedLog
		var started, body string
		if err := rows.Scan(&e.historyID, &e.username, &e.title, &e.subtitle, &e.showTitle,
			&e.deviceName, &e.client, &e.playMethod, &started, &e.stats, &body); err != nil {
			rows.Close()
			log.Printf("ExportPlaybackLogs: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		e.startedAt = parseSQLiteTime(started)
		// Un corps illisible donne un fichier sans lignes plutôt qu'une
		// archive refusée : les mesures, elles, restent bonnes.
		_ = json.Unmarshal([]byte(body), &e.lines)
		logs = append(logs, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		log.Printf("ExportPlaybackLogs: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	archive, err := buildPlaybackLogsZip(logs, zone)
	if err != nil {
		log.Printf("ExportPlaybackLogs: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	name := "onyx-journaux-" + time.Now().In(zone).Format("2006-01-02_15-04") + ".zip"
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(archive)))
	w.Write(archive)
}

// parseExportBound reads a date or an instant. dateOnly tells a bare date.
func parseExportBound(raw string, zone *time.Location) (t time.Time, dateOnly bool, ok bool) {
	if d, err := time.ParseInLocation("2006-01-02", raw, zone); err == nil {
		return d, true, true
	}
	if d, err := time.Parse(time.RFC3339, raw); err == nil {
		return d, false, true
	}
	return time.Time{}, false, false
}

// buildPlaybackLogsZip writes one text file per play, newest first.
func buildPlaybackLogsZip(logs []exportedLog, zone *time.Location) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	used := map[string]bool{}
	for _, l := range logs {
		name := uniqueExportName(exportFileName(l, zone), used)
		f, err := zw.CreateHeader(&zip.FileHeader{
			Name:     name,
			Method:   zip.Deflate,
			Modified: l.startedAt,
		})
		if err != nil {
			return nil, fmt.Errorf("create %s: %w", name, err)
		}
		if _, err := f.Write([]byte(formatPlaybackLogText(l, zone))); err != nil {
			return nil, fmt.Errorf("write %s: %w", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		return nil, fmt.Errorf("close zip: %w", err)
	}
	return buf.Bytes(), nil
}

// exportFileName is `2026-10-30_01-36_Haikyu-S01E05_ChatMallow.txt`.
func exportFileName(l exportedLog, zone *time.Location) string {
	media := l.title
	if l.showTitle != "" {
		media = l.showTitle
		if l.subtitle != "" {
			media += " " + l.subtitle
		}
	}
	parts := []string{
		l.startedAt.In(zone).Format("2006-01-02_15-04"),
		slugForFileName(media, exportTitleMaxRunes, "Sans-titre"),
		slugForFileName(l.username, exportAccountMaxRunes, "Compte"),
	}
	return strings.Join(parts, "_") + ".txt"
}

// slugForFileName keeps letters and digits, joins the rest with a dash, and
// cuts on a character boundary.
//
// Ce que Windows interdit (`\ / : * ? " < > |`), les espaces et la ponctuation
// tombent tous dans « le reste » : une seule règle plutôt qu'une liste de
// caractères interdits qu'un autre système compléterait.
func slugForFileName(s string, max int, fallback string) string {
	var b strings.Builder
	dash := false
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			dash = false
			b.WriteRune(r)
		} else {
			dash = true
		}
	}
	out := b.String()
	if runes := []rune(out); len(runes) > max {
		out = strings.TrimRight(string(runes[:max]), "-")
	}
	if out == "" {
		return fallback
	}
	return out
}

// uniqueExportName suffixes a name already taken with _2, _3…
func uniqueExportName(name string, used map[string]bool) string {
	if !used[name] {
		used[name] = true
		return name
	}
	base := strings.TrimSuffix(name, ".txt")
	for n := 2; ; n++ {
		candidate := fmt.Sprintf("%s_%d.txt", base, n)
		if !used[candidate] {
			used[candidate] = true
			return candidate
		}
	}
}

var exportPlayMethodLabels = map[string]string{
	"direct":        "Direct Play",
	"direct_stream": "Direct Stream",
	"transcode":     "Transcodage",
	"local":         "Fichier téléchargé",
}

// formatPlaybackLogText is the text of the app's « Copier » button: header,
// measurements, then the timestamped lines.
func formatPlaybackLogText(l exportedLog, zone *time.Location) string {
	headline := l.title
	detail := ""
	if l.showTitle != "" {
		headline = l.showTitle
		var parts []string
		if l.subtitle != "" {
			parts = append(parts, l.subtitle)
		}
		detail = strings.Join(append(parts, l.title), " · ")
	}
	method := exportPlayMethodLabels[l.playMethod]
	if method == "" {
		method = exportPlayMethodLabels["direct"]
	}

	lines := []string{headline}
	if detail != "" {
		lines[0] += " · " + detail
	}
	lines = append(lines,
		l.username+" · "+l.deviceName+" · "+l.client,
		method+" · "+l.startedAt.In(zone).Format("2006-01-02 15:04:05"),
	)
	if metrics := describeExportStats(l.stats); len(metrics) > 0 {
		lines = append(lines, "")
		lines = append(lines, metrics...)
	}
	lines = append(lines, "")
	for _, line := range l.lines {
		at := line.At.In(zone)
		lines = append(lines, fmt.Sprintf("%02d:%02d:%02d.%03d · %s",
			at.Hour(), at.Minute(), at.Second(), at.Nanosecond()/1e6, line.Message))
	}
	return strings.Join(lines, "\n") + "\n"
}

// describeExportStats puts the measurements in words, in the order of the
// app's `describePlaybackStats`, which it mirrors: the stats stay opaque to the
// rest of the server, and only this export has to know what the keys mean.
func describeExportStats(raw string) []string {
	if raw == "" {
		return nil
	}
	var s map[string]any
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		return nil
	}
	num := func(key string) (float64, bool) {
		v, ok := s[key].(float64)
		return v, ok
	}
	str := func(key string) string {
		v, _ := s[key].(string)
		return v
	}
	if n, _ := num("sample_count"); n <= 0 {
		return nil
	}

	seconds := func(v float64) string {
		if v < 10 {
			return fmt.Sprintf("%.1f s", v)
		}
		return fmt.Sprintf("%d s", int(math.Round(v)))
	}
	bitrate := func(bps float64) string {
		switch {
		case bps >= 1e6:
			return fmt.Sprintf("%.1f Mb/s", bps/1e6)
		case bps >= 1e3:
			return fmt.Sprintf("%d kb/s", int(math.Round(bps/1e3)))
		}
		return fmt.Sprintf("%d b/s", int(math.Round(bps)))
	}

	var out []string
	add := func(label, value string) { out = append(out, label+" : "+value) }

	fps, hasFps := num("average_fps")
	container, hasContainer := num("container_fps")
	if hasFps {
		if hasContainer && container > 0 {
			add("Images par seconde", fmt.Sprintf("%.1f / %.3f", fps, container))
		} else {
			add("Images par seconde", fmt.Sprintf("%.1f", fps))
		}
	} else if hasContainer {
		add("Cadence du fichier", fmt.Sprintf("%.3f", container))
	}

	dropped, hasDropped := num("dropped_frames")
	rendered, hasRendered := num("rendered_frames")
	switch {
	case hasDropped && hasRendered && dropped+rendered > 0:
		ratio := dropped / (dropped + rendered)
		digits := 1
		if ratio < 0.01 {
			digits = 2
		}
		add("Images perdues", fmt.Sprintf("%d (%.*f %%)", int(dropped), digits, ratio*100))
	case hasDropped:
		add("Images perdues", strconv.Itoa(int(dropped)))
	}

	if v, ok := num("average_bitrate_bps"); ok {
		add("Débit moyen", bitrate(v))
	}
	if v, ok := num("video_bitrate_bps"); ok {
		add("Débit vidéo", bitrate(v))
	}
	if v, ok := num("audio_bitrate_bps"); ok {
		add("Débit audio", bitrate(v))
	}

	if decoder := str("decoder"); decoder != "" {
		if looksSoftwareDecoded(decoder) {
			decoder += " (logiciel)"
		}
		add("Décodage", decoder)
	}
	if v := str("video_codec"); v != "" {
		add("Codec vidéo", v)
	}
	if v := str("audio_codec"); v != "" {
		add("Codec audio", v)
	}

	if ms, ok := num("startup_ms"); ok {
		if ms >= 1000 {
			add("Démarrage", fmt.Sprintf("%.1f s", ms/1000))
		} else {
			add("Démarrage", fmt.Sprintf("%d ms", int(ms)))
		}
	}

	events, _ := num("buffering_events")
	bufSeconds, _ := num("buffering_seconds")
	if events > 0 {
		add("Mises en tampon", fmt.Sprintf("%d · %s", int(events), seconds(bufSeconds)))
	} else {
		add("Mises en tampon", "aucune")
	}

	sampled, _ := num("sampled_seconds")
	add("Mesuré sur", seconds(sampled))
	return out
}

// looksSoftwareDecoded mirrors `PlaybackSessionStats.looksSoftwareDecoded`.
func looksSoftwareDecoded(decoder string) bool {
	name := strings.ToLower(decoder)
	return name == "no" || strings.Contains(name, "omx.google") ||
		strings.Contains(name, "c2.android") || strings.Contains(name, "ffmpeg") ||
		strings.Contains(name, "software")
}
