package handlers

import (
	"archive/zip"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"project-player/server/database"
)

func seedExportedPlay(t *testing.T, fx *activityFixture, userID int, show, sub, title string, started time.Time, body, stats string) int {
	t.Helper()
	res, err := database.DB.Exec(`INSERT INTO playback_history
		(user_id, media_id, media_type, title, subtitle, show_title, device_name, client, play_method, started_at, ended_at, watched_seconds)
		VALUES (?, ?, 'episode', ?, ?, ?, 'Salon', 'Android TV 1.4.2', 'transcode', ?, ?, 120)`,
		userID, fx.episodeID, title, sub, show, historyStamp(started), historyStamp(started.Add(2*time.Minute)))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	if _, err := database.DB.Exec(`INSERT INTO playback_logs (history_id, has_error, line_count, body, stats, updated_at)
		VALUES (?, 0, 1, ?, ?, ?)`, id, body, stats, historyStamp(started)); err != nil {
		t.Fatal(err)
	}
	return int(id)
}

func fetchLogsZip(t *testing.T, query string) (*httptest.ResponseRecorder, map[string]string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/admin/playback-logs.zip"+query, nil)
	rec := httptest.NewRecorder()
	ExportPlaybackLogs(rec, req, nil, 1)
	files := map[string]string{}
	if rec.Code != http.StatusOK {
		return rec, files
	}
	zr, err := zip.NewReader(bytes.NewReader(rec.Body.Bytes()), int64(rec.Body.Len()))
	if err != nil {
		t.Fatalf("zip illisible : %v", err)
	}
	for _, f := range zr.File {
		rc, _ := f.Open()
		data, _ := io.ReadAll(rc)
		rc.Close()
		files[f.Name] = string(data)
	}
	return rec, files
}

func names(files map[string]string) []string {
	out := make([]string, 0, len(files))
	for n := range files {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func TestExportPlaybackLogsNamesAndFillsOneFilePerPlay(t *testing.T) {
	fx := setupActivityTestDB(t)
	started := time.Date(2026, 10, 30, 1, 36, 0, 0, time.UTC)
	seedExportedPlay(t, fx, 3, "Haikyu!!", "S01E05", "Le duel", started,
		`[{"at":"2026-10-30T01:36:07.318Z","level":"info","message":"ouverture"}]`,
		`{"sample_count":3,"sampled_seconds":42,"average_fps":23.9,"container_fps":23.976,"buffering_events":0,"decoder":"c2.android.avc.decoder"}`)
	// Même minute, même média, même compte : le second nom doit se distinguer.
	seedExportedPlay(t, fx, 3, "Haikyu!!", "S01E05", "Le duel", started.Add(10*time.Second), `[]`, ``)

	rec, files := fetchLogsZip(t, "")
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("code %d, type %q", rec.Code, rec.Header().Get("Content-Type"))
	}
	want := []string{"2026-10-30_01-36_Haikyu-S01E05_lea.txt", "2026-10-30_01-36_Haikyu-S01E05_lea_2.txt"}
	if got := names(files); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("noms %v, attendu %v", got, want)
	}

	// L'ordre est du plus récent au plus ancien : le premier nom pris est le
	// second enregistré.
	text := files["2026-10-30_01-36_Haikyu-S01E05_lea_2.txt"]
	for _, expected := range []string{
		"Haikyu!! · S01E05 · Le duel",
		"lea · Salon · Android TV 1.4.2",
		"Transcodage · 2026-10-30 01:36:00",
		"Images par seconde : 23.9 / 23.976",
		"Décodage : c2.android.avc.decoder (logiciel)",
		"Mises en tampon : aucune",
		"Mesuré sur : 42 s",
		"01:36:07.318 · ouverture",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("le fichier ne contient pas %q :\n%s", expected, text)
		}
	}
}

func TestExportPlaybackLogsFiltersByAccountAndPeriod(t *testing.T) {
	fx := setupActivityTestDB(t)
	day := time.Date(2026, 10, 30, 20, 0, 0, 0, time.UTC)
	seedExportedPlay(t, fx, 3, "", "", "Dune", day, `[]`, ``)
	seedExportedPlay(t, fx, 2, "", "", "Dune", day, `[]`, ``)
	seedExportedPlay(t, fx, 3, "", "", "Dune", day.AddDate(0, 0, -5), `[]`, ``)

	_, byUser := fetchLogsZip(t, "?user_id=3")
	if len(byUser) != 2 {
		t.Errorf("user_id=3 : %v", names(byUser))
	}
	// `to` en date inclut la journée entière.
	_, byDay := fetchLogsZip(t, "?from=2026-10-30&to=2026-10-30")
	if len(byDay) != 2 {
		t.Errorf("la journée du 30 : %v", names(byDay))
	}
	id := seedExportedPlay(t, fx, 3, "", "", "Arrival", day.Add(time.Hour), `[]`, ``)
	_, one := fetchLogsZip(t, "?history_id="+strconv.Itoa(id))
	if len(one) != 1 {
		t.Errorf("history_id : %v", names(one))
	}
	if rec, _ := fetchLogsZip(t, "?from=hier"); rec.Code != http.StatusBadRequest {
		t.Errorf("une date illisible doit être refusée, code %d", rec.Code)
	}
}

func TestExportPlaybackLogsFileNamesAreSafe(t *testing.T) {
	zone := time.UTC
	l := exportedLog{
		title:     `Re:Zero <1/2> "?*|\`,
		username:  "Chat Mallow",
		startedAt: time.Date(2026, 10, 30, 1, 36, 0, 0, zone),
	}
	got := exportFileName(l, zone)
	if got != "2026-10-30_01-36_Re-Zero-1-2_Chat-Mallow.txt" {
		t.Errorf("nom assaini : %q", got)
	}
	if strings.ContainsAny(got, `\/:*?"<>|`) {
		t.Errorf("caractère interdit dans %q", got)
	}

	l.title = strings.Repeat("é", 200)
	if n := len([]rune(slugForFileName(l.title, exportTitleMaxRunes, "x"))); n != exportTitleMaxRunes {
		t.Errorf("titre tronqué à %d signes, attendu %d", n, exportTitleMaxRunes)
	}
	if got := exportFileName(exportedLog{startedAt: l.startedAt}, zone); !strings.Contains(got, "Sans-titre") {
		t.Errorf("titre vide : %q", got)
	}
}
