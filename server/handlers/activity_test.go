package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

type activityFixture struct {
	movieID   int
	episodeID int
	clock     time.Time
}

func setupActivityTestDB(t *testing.T) *activityFixture {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "activity.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	mustExec := func(query string, args ...any) int {
		t.Helper()
		res, err := database.DB.Exec(query, args...)
		if err != nil {
			t.Fatalf("%s: %v", query, err)
		}
		id, _ := res.LastInsertId()
		return int(id)
	}
	mustExec(`INSERT INTO users (id, username, password_hash, is_owner, perm_manage_users) VALUES (1, 'owner', 'x', 1, 1)`)
	mustExec(`INSERT INTO users (id, username, password_hash, perm_manage_users) VALUES (2, 'admin', 'x', 1)`)
	mustExec(`INSERT INTO users (id, username, password_hash) VALUES (3, 'lea', 'x')`)

	fx := &activityFixture{clock: time.Date(2026, 9, 14, 20, 0, 0, 0, time.UTC)}
	fx.movieID = mustExec(`INSERT INTO medias (type, title, file_path, duration, poster_url) VALUES (?, 'Dune', '/dune.mkv', 9000, '/dune.jpg')`, models.TypeMovie)
	showID := mustExec(`INSERT INTO medias (type, title, poster_url) VALUES (?, 'Severance', '/sev.jpg')`, models.TypeShow)
	seasonID := mustExec(`INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, 'Saison 2', ?, 2)`, models.TypeSeason, showID)
	fx.episodeID = mustExec(`INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
		VALUES (?, 'Hello, Ms. Cobel', '/sev.mkv', 3000, ?, 2, 1)`, models.TypeEpisode, seasonID)

	playbackActivity = &playbackTracker{now: func() time.Time { return fx.clock }, byKey: map[[32]byte]*activePlayback{}}
	sessionClients.byToken = map[[32]byte]*sessionClient{}
	return fx
}

func (fx *activityFixture) advance(d time.Duration) { fx.clock = fx.clock.Add(d) }

type historyRow struct {
	count   int
	watched int
	title   string
	sub     string
	show    string
	device  string
}

func readHistory(t *testing.T) historyRow {
	t.Helper()
	var row historyRow
	err := database.DB.QueryRow(`SELECT COUNT(*), COALESCE(SUM(watched_seconds), 0), COALESCE(MAX(title), ''),
		COALESCE(MAX(subtitle), ''), COALESCE(MAX(show_title), ''), COALESCE(MAX(device_name), '') FROM playback_history`).
		Scan(&row.count, &row.watched, &row.title, &row.sub, &row.show, &row.device)
	if err != nil {
		t.Fatal(err)
	}
	return row
}

func TestPlaybackActivityCountsOnlyPlayingTime(t *testing.T) {
	fx := setupActivityTestDB(t)
	key := sessionKey("tv-token")
	tv := sessionClient{device: "Salon", client: "Android TV 1.4.2", address: "192.168.1.20"}
	report := func(event string, paused bool, position int) {
		t.Helper()
		if err := playbackActivity.report(key, 3, "lea", tv, PlaybackReport{
			MediaID: fx.episodeID, Position: position, Duration: 3000, Paused: paused, Event: event, PlayMethod: "direct",
		}); err != nil {
			t.Fatal(err)
		}
	}

	report("start", false, 0)
	for i := 1; i <= 4; i++ { // one minute of playback
		fx.advance(15 * time.Second)
		report("progress", false, i*15)
	}
	report("progress", true, 60) // paused from here
	fx.advance(15 * time.Second)
	report("progress", true, 60)
	fx.advance(15 * time.Second)
	report("progress", false, 60)
	fx.advance(15 * time.Second)
	report("progress", false, 75)

	live := playbackActivity.list()
	if len(live) != 1 {
		t.Fatalf("now playing = %d, want 1", len(live))
	}
	if got := live[0]; got.ShowTitle != "Severance" || got.Subtitle != "S02E01" || got.DeviceName != "Salon" || !got.IsLocal || got.Username != "lea" {
		t.Fatalf("unexpected now playing entry: %+v", got)
	}

	fx.advance(10 * time.Second)
	report("stop", false, 85)
	if n := len(playbackActivity.list()); n != 0 {
		t.Fatalf("now playing after stop = %d, want 0", n)
	}
	row := readHistory(t)
	// 60 s + 15 s after resuming + 10 s before stopping. The paused 30 s do not count.
	if row.count != 1 || row.watched != 85 {
		t.Fatalf("history = %+v, want one row of 85 s", row)
	}
	if row.show != "Severance" || row.sub != "S02E01" || row.device != "Salon" {
		t.Fatalf("history snapshot = %+v", row)
	}
}

func TestPlaybackActivityDropsAccidentalOpens(t *testing.T) {
	fx := setupActivityTestDB(t)
	key := sessionKey("phone")
	phone := sessionClient{device: "iPhone"}
	_ = playbackActivity.report(key, 3, "lea", phone, PlaybackReport{MediaID: fx.movieID, Event: "start"})
	fx.advance(10 * time.Second)
	_ = playbackActivity.report(key, 3, "lea", phone, PlaybackReport{MediaID: fx.movieID, Event: "stop"})
	if row := readHistory(t); row.count != 0 {
		t.Fatalf("a 10 s play was kept: %+v", row)
	}
}

func TestPlaybackActivityResumesRecentRowAndReapsQuietDevices(t *testing.T) {
	fx := setupActivityTestDB(t)
	key := sessionKey("desktop")
	mac := sessionClient{device: "Mac"}
	play := func(event string) {
		t.Helper()
		if err := playbackActivity.report(key, 1, "owner", mac, PlaybackReport{MediaID: fx.movieID, Event: event}); err != nil {
			t.Fatal(err)
		}
	}
	play("start")
	for i := 0; i < 4; i++ {
		fx.advance(15 * time.Second)
		play("progress")
	}
	// The app is killed: no stop, the device just goes quiet.
	fx.advance(2 * time.Minute)
	playbackActivity.reap()
	if n := len(playbackActivity.list()); n != 0 {
		t.Fatalf("quiet device still listed: %d", n)
	}
	// Reopened on the same device a minute later: same viewing, same row.
	fx.advance(time.Minute)
	play("start")
	fx.advance(15 * time.Second)
	play("progress")
	play("stop")
	if row := readHistory(t); row.count != 1 || row.watched != 75 {
		t.Fatalf("history = %+v, want the resumed row with 75 s", row)
	}
}

func TestPlaybackStatsGroupsEpisodesAndZeroFillsDays(t *testing.T) {
	fx := setupActivityTestDB(t)
	insert := func(userID int, mediaID any, mediaType, title, show, client string, started time.Time, watched int) {
		t.Helper()
		_, err := database.DB.Exec(`INSERT INTO playback_history (user_id, media_id, media_type, title, show_title,
			client, play_method, started_at, ended_at, watched_seconds) VALUES (?, ?, ?, ?, ?, ?, 'direct', ?, ?, ?)`,
			userID, mediaID, mediaType, title, show, client, historyStamp(started), historyStamp(started), watched)
		if err != nil {
			t.Fatal(err)
		}
	}
	now := fx.clock
	insert(3, fx.episodeID, "episode", "Ep 1", "Severance", "Android TV 1.4.2", now.Add(-2*time.Hour), 3000)
	insert(3, nil, "episode", "Ep 2", "Severance", "Android TV 1.4.3", now.Add(-26*time.Hour), 3000)
	insert(1, fx.movieID, "movie", "Dune", "", "macOS 1.4.3", now.Add(-50*time.Hour), 9000)
	insert(1, fx.movieID, "movie", "Dune", "", "macOS 1.4.3", now.Add(-40*24*time.Hour), 9000) // outside the window
	insert(1, fx.movieID, "movie", "Dune", "", "macOS 1.4.3", now.Add(-time.Hour), 12)         // too short to count

	// open() records the show of an episode; these hand-written rows need it too.
	if _, err := database.DB.Exec(`UPDATE playback_history SET show_id = (SELECT id FROM medias WHERE type = 'show')
		WHERE media_type = 'episode'`); err != nil {
		t.Fatal(err)
	}

	stats, err := computePlaybackStats(0, 7, 120, now, true)
	if err != nil {
		t.Fatal(err)
	}
	if stats.Totals.Plays != 3 || stats.Totals.Watched != 15000 || stats.Totals.ActiveUsers != 2 || stats.Totals.Episodes != 2 || stats.Totals.Movies != 1 {
		t.Fatalf("totals = %+v", stats.Totals)
	}
	if len(stats.Daily) != 7 || stats.Daily[6].Date != "2026-09-14" || stats.Daily[6].Watched != 3000 {
		t.Fatalf("daily = %+v", stats.Daily)
	}
	if len(stats.TopMedia) != 2 || stats.TopMedia[0].Label != "Dune" || stats.TopMedia[1].Label != "Severance" ||
		stats.TopMedia[1].Plays != 2 || stats.TopMedia[1].MediaType != "show" || stats.TopMedia[1].PosterURL != "/sev.jpg" {
		t.Fatalf("top media = %+v", stats.TopMedia)
	}
	if len(stats.Clients) != 2 || stats.Clients[0].Label != "macOS" || stats.Clients[1].Label != "Android TV" || stats.Clients[1].Plays != 2 {
		t.Fatalf("clients = %+v", stats.Clients)
	}
	if len(stats.TopUsers) != 2 || stats.TopUsers[0].Label != "owner" {
		t.Fatalf("top users = %+v", stats.TopUsers)
	}

	mine, err := computePlaybackStats(3, 7, 120, now, false)
	if err != nil {
		t.Fatal(err)
	}
	if mine.Totals.Plays != 2 || mine.TopUsers != nil {
		t.Fatalf("own stats leaked other users: %+v", mine)
	}
}

func insertSession(t *testing.T, token string, userID int) int64 {
	t.Helper()
	res, err := database.DB.Exec(`INSERT INTO sessions (token, user_id) VALUES (?, ?)`, token, userID)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func bearerRequest(method, path, token string, body []byte) *http.Request {
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

func TestDevicesRecordClientAndReportPlayback(t *testing.T) {
	fx := setupActivityTestDB(t)
	insertSession(t, "lea-tv", 3)
	insertSession(t, "lea-phone", 3)

	router := httprouter.New()
	router.POST("/api/playing", RequireAuth(ReportPlayback))
	router.GET("/api/me/devices", RequireAuth(ListMyDevices))

	body, _ := json.Marshal(PlaybackReport{MediaID: fx.movieID, Event: "start", PlayMethod: "transcode"})
	req := bearerRequest(http.MethodPost, "/api/playing", "lea-tv", body)
	req.Header.Set(headerDevice, "T%C3%A9l%C3%A9 Salon%0A")
	req.Header.Set(headerClient, "Android TV 1.4.2")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("report status = %d: %s", rec.Code, rec.Body)
	}

	var stored string
	if err := database.DB.QueryRow(`SELECT device_name FROM sessions WHERE token = 'lea-tv'`).Scan(&stored); err != nil || stored != "Télé Salon" {
		t.Fatalf("device name stored = %q (%v)", stored, err)
	}

	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, bearerRequest(http.MethodGet, "/api/me/devices", "lea-phone", nil))
	var devices []Device
	if err := json.Unmarshal(rec.Body.Bytes(), &devices); err != nil {
		t.Fatalf("decode devices: %v (%s)", err, rec.Body)
	}
	if len(devices) != 2 {
		t.Fatalf("devices = %+v", devices)
	}
	var tv, phone Device
	for _, d := range devices {
		if d.DeviceName == "Télé Salon" {
			tv = d
		} else {
			phone = d
		}
	}
	if tv.NowPlaying != "Dune" || tv.Client != "Android TV 1.4.2" || tv.IsCurrent || !phone.IsCurrent {
		t.Fatalf("tv = %+v, phone = %+v", tv, phone)
	}
	if live := playbackActivity.list(); len(live) != 1 || live[0].PlayMethod != "transcode" {
		t.Fatalf("now playing = %+v", live)
	}
}

func TestRevokeDevicesRespectsOwnership(t *testing.T) {
	setupActivityTestDB(t)
	ownerDevice := insertSession(t, "owner-mac", 1)
	adminDevice := insertSession(t, "admin-pc", 2)
	leaDevice := insertSession(t, "lea-tv", 3)

	router := httprouter.New()
	router.DELETE("/api/me/devices/:id", RequireAuth(RevokeMyDevice))
	router.DELETE("/api/admin/devices/:id", RequirePermission(models.PermManageUsers, RevokeAnyDevice))
	call := func(path, token string) int {
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, bearerRequest(http.MethodDelete, path, token, nil))
		return rec.Code
	}
	id := func(n int64) string { return strconv.FormatInt(n, 10) }

	if code := call("/api/me/devices/"+id(ownerDevice), "lea-tv"); code != http.StatusNotFound {
		t.Fatalf("a user revoked someone else's device: %d", code)
	}
	if code := call("/api/admin/devices/"+id(leaDevice), "lea-tv"); code != http.StatusForbidden {
		t.Fatalf("a plain user reached the admin route: %d", code)
	}
	if code := call("/api/admin/devices/"+id(ownerDevice), "admin-pc"); code != http.StatusForbidden {
		t.Fatalf("an admin signed the owner out: %d", code)
	}
	if code := call("/api/admin/devices/"+id(leaDevice), "admin-pc"); code != http.StatusNoContent {
		t.Fatalf("admin revoke = %d", code)
	}
	if code := call("/api/admin/devices/"+id(adminDevice), "owner-mac"); code != http.StatusNoContent {
		t.Fatalf("owner revoke = %d", code)
	}
	var remaining int
	database.DB.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&remaining)
	if remaining != 1 {
		t.Fatalf("sessions left = %d, want only the owner's", remaining)
	}
}
