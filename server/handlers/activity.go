package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Activité de lecture : qui regarde quoi en ce moment, et ce qui a été regardé.
//
// La progression (progress.go) ne suffit pas à le dire : elle ne garde qu'une
// position par compte et par média, écrasée à chaque battement, et elle ne sait
// ni sur quel appareil ni combien de temps on a réellement regardé. Le lecteur
// envoie donc en plus un signal de lecture (POST /api/playing) — au démarrage,
// toutes les 15 secondes, pause comprise, et à l'arrêt.
//
// Les lectures en cours vivent en mémoire, une par session (donc par appareil).
// Chacune tient une ligne de playback_history à jour : un redémarrage du
// serveur ne perd que les dernières secondes, et une lecture reprise dans les
// minutes qui suivent continue la même ligne au lieu d'en ouvrir une seconde.

const (
	// A device that has not reported for this long has stopped playing — its
	// app was killed, the network dropped, the television was switched off.
	playbackStaleAfter = 60 * time.Second
	// Time between two reports counts as watched only if the gap is plausible
	// for a 15 s heartbeat. A longer gap is a suspended app, not a film.
	playbackMaxCountedGap = 45 * time.Second
	// A play reopened on the same device within this window continues its row.
	playbackResumeWindow = 5 * time.Minute
	// Plays shorter than this are an accidental open, not a viewing: they are
	// dropped from the history once they end.
	playbackMinSeconds = 30
)

// PlaybackReport is what the player sends (POST /api/playing).
type PlaybackReport struct {
	MediaID  int  `json:"media_id"`
	Position int  `json:"position_seconds"`
	Duration int  `json:"duration_seconds"`
	Paused   bool `json:"paused"`
	// PlayMethod is "direct", "direct_stream", "transcode" or "local".
	PlayMethod string `json:"play_method"`
	Quality    string `json:"quality"`
	// Event is "start", "progress" (default) or "stop".
	Event string `json:"event"`
}

// NowPlaying is one live playback, as shown on the dashboard.
type NowPlaying struct {
	SessionID  string    `json:"session_id"`
	UserID     int       `json:"user_id"`
	Username   string    `json:"username"`
	DeviceName string    `json:"device_name"`
	Client     string    `json:"client"`
	Address    string    `json:"address,omitempty"`
	IsLocal    bool      `json:"is_local"`
	MediaID    int       `json:"media_id"`
	MediaType  string    `json:"media_type"`
	Title      string    `json:"title"`
	Subtitle   string    `json:"subtitle,omitempty"`
	ShowTitle  string    `json:"show_title,omitempty"`
	PosterURL  string    `json:"poster_url,omitempty"`
	Position   int       `json:"position_seconds"`
	Duration   int       `json:"duration_seconds"`
	Paused     bool      `json:"paused"`
	PlayMethod string    `json:"play_method"`
	Quality    string    `json:"quality,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	UpdatedAt  time.Time `json:"updated_at"`
	Watched    int       `json:"watched_seconds"`
}

type activePlayback struct {
	NowPlaying
	showID    sql.NullInt64
	historyID int64
}

type playbackTracker struct {
	mu    sync.Mutex
	now   func() time.Time
	byKey map[[32]byte]*activePlayback
}

var playbackActivity = &playbackTracker{now: time.Now, byKey: make(map[[32]byte]*activePlayback)}

// mediaSnapshot is what the history keeps of a media, frozen at play time.
type mediaSnapshot struct {
	mediaType string
	title     string
	subtitle  string
	showID    sql.NullInt64
	showTitle string
	posterURL string
}

func loadMediaSnapshot(mediaID int) (mediaSnapshot, error) {
	var snap mediaSnapshot
	var season, episode int
	var poster sql.NullString
	err := database.DB.QueryRow(`
		SELECT m.type, m.title, COALESCE(m.season_number, 0), COALESCE(m.episode_number, 0),
		       show.id, COALESCE(show.title, ''),
		       COALESCE(NULLIF(show.poster_url, ''), NULLIF(m.poster_url, ''), '')
		FROM medias m
		LEFT JOIN medias season ON season.id = m.parent_id AND m.type = 'episode'
		LEFT JOIN medias show ON show.id = season.parent_id
		WHERE m.id = ?`, mediaID,
	).Scan(&snap.mediaType, &snap.title, &season, &episode, &snap.showID, &snap.showTitle, &poster)
	if err != nil {
		return snap, err
	}
	snap.posterURL = poster.String
	if snap.mediaType == string(models.TypeEpisode) && (season > 0 || episode > 0) {
		snap.subtitle = fmt.Sprintf("S%02dE%02d", season, episode)
	}
	return snap, nil
}

func historyStamp(t time.Time) string { return t.UTC().Format(sqliteTimeLayout) }

func normalizePlayMethod(raw string) string {
	switch raw {
	case "direct", "direct_stream", "transcode", "local":
		return raw
	}
	return "direct"
}

// report applies one heartbeat. Database work happens outside the lock: a slow
// write must not stall every other device's report.
func (t *playbackTracker) report(key [32]byte, userID int, username string, client sessionClient, req PlaybackReport) error {
	now := t.now()

	t.mu.Lock()
	entry := t.byKey[key]
	var ended *activePlayback
	if entry != nil && (entry.MediaID != req.MediaID || req.Event == "stop") {
		t.countWatchedLocked(entry, now)
		if req.Event == "stop" && entry.MediaID == req.MediaID {
			entry.Position = req.Position
		}
		ended = entry
		delete(t.byKey, key)
		entry = nil
	}
	t.mu.Unlock()

	if ended != nil {
		finishHistoryRow(ended)
	}
	if req.Event == "stop" {
		return nil
	}

	if entry == nil {
		created, err := t.open(key, userID, username, client, req, now)
		if err != nil {
			return err
		}
		t.mu.Lock()
		if existing := t.byKey[key]; existing != nil && existing.MediaID == req.MediaID {
			// A concurrent report won the race; keep its entry.
			entry = existing
		} else {
			t.byKey[key] = created
			entry = created
		}
		t.mu.Unlock()
	}

	t.mu.Lock()
	t.countWatchedLocked(entry, now)
	entry.Position = req.Position
	if req.Duration > 0 {
		entry.Duration = req.Duration
	}
	entry.Paused = req.Paused
	entry.PlayMethod = normalizePlayMethod(req.PlayMethod)
	entry.Quality = cleanClientLabel(req.Quality)
	entry.Address = client.address
	entry.IsLocal = isLocalAddress(client.address)
	if client.device != "" {
		entry.DeviceName = client.device
	}
	if client.client != "" {
		entry.Client = client.client
	}
	snapshot := *entry
	t.mu.Unlock()

	return writeHistoryRow(&snapshot)
}

// countWatchedLocked credits the time since the last report, if the player was
// playing during it.
func (t *playbackTracker) countWatchedLocked(entry *activePlayback, now time.Time) {
	gap := now.Sub(entry.UpdatedAt)
	if !entry.Paused && gap > 0 && gap <= playbackMaxCountedGap {
		entry.Watched += int(gap.Round(time.Second).Seconds())
	}
	entry.UpdatedAt = now
}

func (t *playbackTracker) open(key [32]byte, userID int, username string, client sessionClient, req PlaybackReport, now time.Time) (*activePlayback, error) {
	snap, err := loadMediaSnapshot(req.MediaID)
	if err != nil {
		return nil, err
	}
	entry := &activePlayback{
		NowPlaying: NowPlaying{
			SessionID:  fmt.Sprintf("%x", key[:6]),
			UserID:     userID,
			Username:   username,
			DeviceName: client.device,
			Client:     client.client,
			MediaID:    req.MediaID,
			MediaType:  snap.mediaType,
			Title:      snap.title,
			Subtitle:   snap.subtitle,
			ShowTitle:  snap.showTitle,
			PosterURL:  snap.posterURL,
			Duration:   req.Duration,
			StartedAt:  now.UTC(),
			UpdatedAt:  now,
			PlayMethod: normalizePlayMethod(req.PlayMethod),
		},
		showID: snap.showID,
	}

	// Continue a row this device left moments ago: leaving the player to pick
	// a subtitle file, or a server restart, is still the same viewing.
	var startedAt string
	err = database.DB.QueryRow(`
		SELECT id, watched_seconds, CAST(started_at AS TEXT) FROM playback_history
		WHERE user_id = ? AND media_id = ? AND device_name = ? AND ended_at >= ?
		ORDER BY id DESC LIMIT 1`,
		userID, req.MediaID, client.device, historyStamp(now.Add(-playbackResumeWindow)),
	).Scan(&entry.historyID, &entry.Watched, &startedAt)
	if err == nil {
		if started := parseSQLiteTime(startedAt); !started.IsZero() {
			entry.StartedAt = started
		}
		return entry, nil
	}
	if err != sql.ErrNoRows {
		return nil, err
	}

	res, err := database.DB.Exec(`
		INSERT INTO playback_history (user_id, media_id, media_type, title, subtitle, show_id, show_title,
			device_name, client, play_method, started_at, ended_at, position_seconds, duration_seconds)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, req.MediaID, snap.mediaType, snap.title, snap.subtitle, snap.showID, snap.showTitle,
		client.device, client.client, entry.PlayMethod, historyStamp(now), historyStamp(now), req.Position, req.Duration,
	)
	if err != nil {
		return nil, err
	}
	entry.historyID, _ = res.LastInsertId()
	return entry, nil
}

func writeHistoryRow(entry *activePlayback) error {
	if entry.historyID == 0 {
		return nil
	}
	_, err := database.DB.Exec(`
		UPDATE playback_history SET ended_at = ?, watched_seconds = ?, position_seconds = ?,
			duration_seconds = ?, play_method = ?, device_name = CASE WHEN ? != '' THEN ? ELSE device_name END,
			client = CASE WHEN ? != '' THEN ? ELSE client END
		WHERE id = ?`,
		historyStamp(entry.UpdatedAt), entry.Watched, entry.Position, entry.Duration, entry.PlayMethod,
		entry.DeviceName, entry.DeviceName, entry.Client, entry.Client, entry.historyID,
	)
	return err
}

func finishHistoryRow(entry *activePlayback) {
	if err := writeHistoryRow(entry); err != nil {
		log.Printf("Activity: failed to close a history row: %v", err)
		return
	}
	// Sauf quand elle a laissé une erreur derrière elle : voir
	// [playbackHasErrorLog]. Une lecture qui n'a jamais démarré dure zéro
	// seconde, et c'est celle qu'on cherchera dans l'historique.
	if entry.Watched < playbackMinSeconds && !playbackHasErrorLog(entry.historyID) {
		if _, err := database.DB.Exec(`DELETE FROM playback_history WHERE id = ?`, entry.historyID); err != nil {
			log.Printf("Activity: failed to drop a short play: %v", err)
		}
	}
}

// reap closes plays whose device went quiet.
func (t *playbackTracker) reap() {
	now := t.now()
	var ended []*activePlayback
	t.mu.Lock()
	for key, entry := range t.byKey {
		if now.Sub(entry.UpdatedAt) > playbackStaleAfter {
			ended = append(ended, entry)
			delete(t.byKey, key)
		}
	}
	t.mu.Unlock()
	for _, entry := range ended {
		finishHistoryRow(entry)
	}
}

func (t *playbackTracker) dropSession(key [32]byte) {
	t.mu.Lock()
	entry := t.byKey[key]
	delete(t.byKey, key)
	t.mu.Unlock()
	if entry != nil {
		finishHistoryRow(entry)
	}
}

func (t *playbackTracker) list() []NowPlaying {
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]NowPlaying, 0, len(t.byKey))
	for _, entry := range t.byKey {
		if now.Sub(entry.UpdatedAt) > playbackStaleAfter {
			continue
		}
		item := entry.NowPlaying
		item.UpdatedAt = item.UpdatedAt.UTC()
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt.Before(out[j].StartedAt) })
	return out
}

func (t *playbackTracker) count() int { return len(t.list()) }

func (t *playbackTracker) titlesBySession() map[[32]byte]string {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make(map[[32]byte]string, len(t.byKey))
	for key, entry := range t.byKey {
		title := entry.Title
		if entry.ShowTitle != "" {
			title = entry.ShowTitle + " · " + entry.Subtitle
		}
		out[key] = title
	}
	return out
}

// historyIDFor returns the history row this session's live play is writing to.
//
// Vérifie le compte autant que la session : deux jetons ne partagent pas une
// clé, mais le journal d'une lecture est une donnée de séance, et rien ne doit
// pouvoir l'écrire sur celle de quelqu'un d'autre parce qu'une clé aurait été
// devinée.
func (t *playbackTracker) historyIDFor(key [32]byte, userID int) (int64, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	entry := t.byKey[key]
	if entry == nil || entry.historyID == 0 || entry.UserID != userID {
		return 0, false
	}
	return entry.historyID, true
}

// RunPlaybackActivity sweeps quiet plays until ctx ends.
func RunPlaybackActivity(ctx context.Context) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			playbackActivity.reap()
		}
	}
}

// ReportPlayback receives the player's heartbeat (POST /api/playing).
func ReportPlayback(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var req PlaybackReport
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || req.MediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid playback report")
		return
	}
	if req.Position < 0 {
		req.Position = 0
	}
	token := bearerToken(r)
	client, _ := sessionClientSnapshot(token)
	if client.address == "" {
		client.address = clientAddress(r)
	}
	var username string
	_ = database.DB.QueryRow(`SELECT username FROM users WHERE id = ?`, userID).Scan(&username)

	if err := playbackActivity.report(sessionKey(token), userID, username, client, req); err != nil {
		if err == sql.ErrNoRows {
			writeJSONError(w, http.StatusNotFound, "Media not found")
			return
		}
		log.Printf("ReportPlayback: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ListNowPlaying returns the live plays (GET /api/admin/activity, manage_users).
func ListNowPlaying(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(playbackActivity.list())
}

// HistoryEntry is one finished or ongoing play.
type HistoryEntry struct {
	ID         int64     `json:"id"`
	UserID     int       `json:"user_id"`
	Username   string    `json:"username"`
	MediaID    int       `json:"media_id,omitempty"`
	MediaType  string    `json:"media_type"`
	Title      string    `json:"title"`
	Subtitle   string    `json:"subtitle,omitempty"`
	ShowTitle  string    `json:"show_title,omitempty"`
	PosterURL  string    `json:"poster_url,omitempty"`
	DeviceName string    `json:"device_name"`
	Client     string    `json:"client"`
	PlayMethod string    `json:"play_method"`
	StartedAt  time.Time `json:"started_at"`
	EndedAt    time.Time `json:"ended_at"`
	Watched    int       `json:"watched_seconds"`
	Position   int       `json:"position_seconds"`
	Duration   int       `json:"duration_seconds"`
}

func queryHistory(userID int, limit int, beforeID int64) ([]HistoryEntry, error) {
	query := `
		SELECT h.id, h.user_id, COALESCE(u.username, ''), COALESCE(h.media_id, 0), h.media_type, h.title,
		       h.subtitle, h.show_title,
		       COALESCE(NULLIF(show.poster_url, ''), NULLIF(m.poster_url, ''), ''),
		       h.device_name, h.client, h.play_method, CAST(h.started_at AS TEXT), CAST(h.ended_at AS TEXT),
		       h.watched_seconds, h.position_seconds, h.duration_seconds
		FROM playback_history h
		LEFT JOIN users u ON u.id = h.user_id
		LEFT JOIN medias m ON m.id = h.media_id
		LEFT JOIN medias show ON show.id = h.show_id
		WHERE h.watched_seconds >= ?`
	args := []any{playbackMinSeconds}
	if userID > 0 {
		query += ` AND h.user_id = ?`
		args = append(args, userID)
	}
	if beforeID > 0 {
		query += ` AND h.id < ?`
		args = append(args, beforeID)
	}
	query += ` ORDER BY h.id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := database.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries := []HistoryEntry{}
	for rows.Next() {
		var e HistoryEntry
		var started, ended string
		if err := rows.Scan(&e.ID, &e.UserID, &e.Username, &e.MediaID, &e.MediaType, &e.Title, &e.Subtitle,
			&e.ShowTitle, &e.PosterURL, &e.DeviceName, &e.Client, &e.PlayMethod, &started, &ended,
			&e.Watched, &e.Position, &e.Duration); err != nil {
			return nil, err
		}
		e.StartedAt = parseSQLiteTime(started)
		e.EndedAt = parseSQLiteTime(ended)
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func queryInt(r *http.Request, name string, fallback, min, max int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil {
		return fallback
	}
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}

// ListPlaybackHistory pages through every play (GET /api/admin/history,
// manage_users). Filters: user_id, before_id, limit.
func ListPlaybackHistory(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	userFilter := queryInt(r, "user_id", 0, 0, 1<<31-1)
	beforeID, _ := strconv.ParseInt(r.URL.Query().Get("before_id"), 10, 64)
	entries, err := queryHistory(userFilter, queryInt(r, "limit", 50, 1, 200), beforeID)
	if err != nil {
		log.Printf("ListPlaybackHistory: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(entries)
}

// ClearPlaybackHistory empties the history (DELETE /api/admin/history,
// manage_users). Plays in progress stay on the dashboard but are no longer
// recorded; the next play of each device starts afresh.
func ClearPlaybackHistory(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, _ int) {
	playbackActivity.mu.Lock()
	for _, entry := range playbackActivity.byKey {
		entry.historyID = 0
	}
	playbackActivity.mu.Unlock()
	if _, err := database.DB.Exec(`DELETE FROM playback_history`); err != nil {
		log.Printf("ClearPlaybackHistory: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ==================== Statistics ====================

type statBucket struct {
	Key       string `json:"key"`
	Label     string `json:"label"`
	Secondary string `json:"secondary,omitempty"`
	PosterURL string `json:"poster_url,omitempty"`
	MediaType string `json:"media_type,omitempty"`
	Plays     int    `json:"plays"`
	Watched   int    `json:"watched_seconds"`
}

type dailyStat struct {
	Date    string `json:"date"`
	Plays   int    `json:"plays"`
	Watched int    `json:"watched_seconds"`
}

// PlaybackStats summarises a period of viewing.
type PlaybackStats struct {
	Days   int `json:"days"`
	Totals struct {
		Plays       int `json:"plays"`
		Watched     int `json:"watched_seconds"`
		ActiveUsers int `json:"active_users"`
		Movies      int `json:"movies"`
		Episodes    int `json:"episodes"`
	} `json:"totals"`
	Daily       []dailyStat  `json:"daily"`
	HourOfDay   []int        `json:"hour_of_day"`
	TopUsers    []statBucket `json:"top_users,omitempty"`
	TopMedia    []statBucket `json:"top_media"`
	Clients     []statBucket `json:"clients"`
	PlayMethods []statBucket `json:"play_methods"`
}

// tzModifier renders a UTC offset as a SQLite date modifier.
func tzModifier(offsetMinutes int) string {
	return fmt.Sprintf("%+d minutes", offsetMinutes)
}

func computePlaybackStats(userID, days, offsetMinutes int, now time.Time, includeUsers bool) (*PlaybackStats, error) {
	stats := &PlaybackStats{Days: days, Daily: []dailyStat{}, HourOfDay: make([]int, 24)}
	zone := time.FixedZone("client", offsetMinutes*60)
	localNow := now.In(zone)
	firstDay := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, zone).AddDate(0, 0, -(days - 1))
	since := historyStamp(firstDay)
	modifier := tzModifier(offsetMinutes)

	where := ` WHERE h.started_at >= ? AND h.watched_seconds >= ?`
	args := []any{since, playbackMinSeconds}
	if userID > 0 {
		where += ` AND h.user_id = ?`
		args = append(args, userID)
	}

	err := database.DB.QueryRow(`
		SELECT COUNT(*), COALESCE(SUM(h.watched_seconds), 0), COUNT(DISTINCT h.user_id),
		       COUNT(DISTINCT CASE WHEN h.media_type = 'movie' THEN COALESCE(h.media_id, h.title) END),
		       COUNT(DISTINCT CASE WHEN h.media_type = 'episode' THEN COALESCE(h.media_id, h.title) END)
		FROM playback_history h`+where, args...,
	).Scan(&stats.Totals.Plays, &stats.Totals.Watched, &stats.Totals.ActiveUsers, &stats.Totals.Movies, &stats.Totals.Episodes)
	if err != nil {
		return nil, err
	}

	// Daily series, zero-filled so the chart has one bar per day.
	byDay := map[string]dailyStat{}
	rows, err := database.DB.Query(`
		SELECT strftime('%Y-%m-%d', h.started_at, ?), COUNT(*), COALESCE(SUM(h.watched_seconds), 0)
		FROM playback_history h`+where+` GROUP BY 1`, append([]any{modifier}, args...)...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var d dailyStat
		if err := rows.Scan(&d.Date, &d.Plays, &d.Watched); err != nil {
			rows.Close()
			return nil, err
		}
		byDay[d.Date] = d
	}
	rows.Close()
	for i := 0; i < days; i++ {
		date := firstDay.AddDate(0, 0, i).Format("2006-01-02")
		day := byDay[date]
		day.Date = date
		stats.Daily = append(stats.Daily, day)
	}

	rows, err = database.DB.Query(`
		SELECT CAST(strftime('%H', h.started_at, ?) AS INTEGER), COALESCE(SUM(h.watched_seconds), 0)
		FROM playback_history h`+where+` GROUP BY 1`, append([]any{modifier}, args...)...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var hour, watched int
		if err := rows.Scan(&hour, &watched); err != nil {
			rows.Close()
			return nil, err
		}
		if hour >= 0 && hour < 24 {
			stats.HourOfDay[hour] = watched
		}
	}
	rows.Close()

	bucketQuery := func(selectKey, selectLabel, selectSecondary, selectPoster, selectType, joins string, limit int) ([]statBucket, error) {
		rows, err := database.DB.Query(`
			SELECT `+selectKey+`, `+selectLabel+`, `+selectSecondary+`, `+selectPoster+`, `+selectType+`,
			       COUNT(*), COALESCE(SUM(h.watched_seconds), 0)
			FROM playback_history h `+joins+where+`
			GROUP BY 1 ORDER BY 7 DESC, 6 DESC LIMIT ?`, append(args, limit)...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		buckets := []statBucket{}
		for rows.Next() {
			var b statBucket
			if err := rows.Scan(&b.Key, &b.Label, &b.Secondary, &b.PosterURL, &b.MediaType, &b.Plays, &b.Watched); err != nil {
				return nil, err
			}
			buckets = append(buckets, b)
		}
		return buckets, rows.Err()
	}

	if includeUsers {
		stats.TopUsers, err = bucketQuery(`CAST(h.user_id AS TEXT)`, `COALESCE(MAX(u.username), '')`, `''`, `''`, `''`,
			`LEFT JOIN users u ON u.id = h.user_id`, 10)
		if err != nil {
			return nil, err
		}
	}

	// Episodes count towards their show: "Severance, 14 lectures" says more
	// than fourteen separate episode lines.
	stats.TopMedia, err = bucketQuery(
		`CASE WHEN h.media_type = 'episode' AND COALESCE(h.show_title, '') != '' THEN 'show:' || h.show_title
		      ELSE 'media:' || COALESCE(CAST(h.media_id AS TEXT), h.title) END`,
		`CASE WHEN h.media_type = 'episode' AND COALESCE(h.show_title, '') != '' THEN MAX(h.show_title) ELSE MAX(h.title) END`,
		`CASE WHEN h.media_type = 'episode' THEN COUNT(DISTINCT COALESCE(h.media_id, h.title)) || ' épisode(s)' ELSE '' END`,
		`COALESCE(MAX(NULLIF(show.poster_url, '')), MAX(NULLIF(m.poster_url, '')), '')`,
		`CASE WHEN h.media_type = 'episode' AND COALESCE(h.show_title, '') != '' THEN 'show' ELSE MAX(h.media_type) END`,
		`LEFT JOIN medias m ON m.id = h.media_id LEFT JOIN medias show ON show.id = h.show_id`, 10)
	if err != nil {
		return nil, err
	}

	stats.Clients, err = bucketQuery(`COALESCE(NULLIF(h.client, ''), 'Inconnu')`, `COALESCE(NULLIF(h.client, ''), 'Inconnu')`,
		`''`, `''`, `''`, ``, 8)
	if err != nil {
		return nil, err
	}
	stats.PlayMethods, err = bucketQuery(`COALESCE(NULLIF(h.play_method, ''), 'direct')`, `COALESCE(NULLIF(h.play_method, ''), 'direct')`,
		`''`, `''`, `''`, ``, 4)
	if err != nil {
		return nil, err
	}
	// Clients report "Android TV 1.4.2": grouping by the full label would split
	// one platform across every release, so the version is folded here.
	stats.Clients = foldClientVersions(stats.Clients)
	return stats, nil
}

func foldClientVersions(buckets []statBucket) []statBucket {
	merged := map[string]*statBucket{}
	var order []string
	for _, b := range buckets {
		label := b.Label
		if fields := strings.Fields(label); len(fields) > 1 {
			last := fields[len(fields)-1]
			if last != "" && (last[0] >= '0' && last[0] <= '9') {
				label = strings.Join(fields[:len(fields)-1], " ")
			}
		}
		if existing, ok := merged[label]; ok {
			existing.Plays += b.Plays
			existing.Watched += b.Watched
			continue
		}
		folded := b
		folded.Key = label
		folded.Label = label
		merged[label] = &folded
		order = append(order, label)
	}
	out := make([]statBucket, 0, len(order))
	for _, label := range order {
		out = append(out, *merged[label])
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Watched > out[j].Watched })
	return out
}

func writeStats(w http.ResponseWriter, r *http.Request, userID int, includeUsers bool) {
	days := queryInt(r, "days", 30, 1, 365)
	offset := queryInt(r, "tz_offset", 0, -14*60, 14*60)
	stats, err := computePlaybackStats(userID, days, offset, time.Now(), includeUsers)
	if err != nil {
		log.Printf("PlaybackStats: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// GetPlaybackStats covers the whole server (GET /api/admin/stats, manage_users).
func GetPlaybackStats(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	writeStats(w, r, queryInt(r, "user_id", 0, 0, 1<<31-1), true)
}

// GetMyPlaybackStats covers the caller's own viewing (GET /api/me/stats).
func GetMyPlaybackStats(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	writeStats(w, r, userID, false)
}
