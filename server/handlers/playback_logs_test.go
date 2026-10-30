package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
)

func logLines(n int, level string) []PlaybackLogLine {
	out := make([]PlaybackLogLine, n)
	for i := range out {
		out[i] = PlaybackLogLine{
			At:      time.Date(2026, 9, 18, 12, 0, i%60, 0, time.UTC),
			Level:   level,
			Message: "ligne " + strings.Repeat("x", 4),
		}
	}
	return out
}

func TestNormalizePlaybackLogsKeepsTheEnd(t *testing.T) {
	in := logLines(playbackLogMaxLines+40, "info")
	// Marque la toute dernière : c'est celle qui doit survivre.
	in[len(in)-1].Message = "la dernière"

	out, hasError := normalizePlaybackLogLines(in)

	if len(out) != playbackLogMaxLines {
		t.Fatalf("gardé %d lignes, attendu %d", len(out), playbackLogMaxLines)
	}
	if out[len(out)-1].Message != "la dernière" {
		t.Errorf("la dernière ligne a été écartée : %q", out[len(out)-1].Message)
	}
	if hasError {
		t.Error("aucune ligne n'était une erreur")
	}
}

func TestNormalizePlaybackLogsReadsTheErrorFromTheLines(t *testing.T) {
	in := logLines(3, "info")
	in[1].Level = "error"

	out, hasError := normalizePlaybackLogLines(in)

	if !hasError {
		t.Fatal("une ligne d'erreur devait être vue")
	}
	if out[1].Level != "error" || out[0].Level != "info" {
		t.Errorf("les niveaux ont bougé : %q puis %q", out[0].Level, out[1].Level)
	}
}

func TestNormalizePlaybackLogsNormalisesUnknownLevels(t *testing.T) {
	// Un client qui inventerait un niveau ne doit pas pouvoir écrire dans la
	// base une valeur que l'interface ne sait pas rendre.
	out, hasError := normalizePlaybackLogLines([]PlaybackLogLine{
		{Level: "ERROR", Message: "criant"},
		{Level: "warn", Message: "tiède"},
	})

	if hasError {
		t.Error("« ERROR » n'est pas « error » : rien ne doit être promu")
	}
	for _, line := range out {
		if line.Level != "info" {
			t.Errorf("niveau %q laissé passer", line.Level)
		}
	}
}

func TestNormalizePlaybackLogsDropsBlankLines(t *testing.T) {
	out, _ := normalizePlaybackLogLines([]PlaybackLogLine{
		{Level: "info", Message: "   "},
		{Level: "info", Message: "  utile  "},
		{Level: "info", Message: ""},
	})

	if len(out) != 1 || out[0].Message != "utile" {
		t.Fatalf("attendu une seule ligne rognée, reçu %#v", out)
	}
}

func TestNormalizePlaybackLogsCutsOnCharacterBoundaries(t *testing.T) {
	// Des caractères de plusieurs octets, en nombre suffisant pour dépasser le
	// plafond : couper sur un octet produirait de l'UTF-8 invalide.
	long := strings.Repeat("é", playbackLogMaxLineLength+50)

	out, _ := normalizePlaybackLogLines([]PlaybackLogLine{{Message: long}})

	if len(out) != 1 {
		t.Fatalf("attendu une ligne, reçu %d", len(out))
	}
	got := out[0].Message
	if !strings.HasSuffix(got, "…") {
		t.Error("la troncature n'est pas marquée")
	}
	if n := len([]rune(strings.TrimSuffix(got, "…"))); n != playbackLogMaxLineLength {
		t.Errorf("tronqué à %d caractères, attendu %d", n, playbackLogMaxLineLength)
	}
	if !isValidUTF8(got) {
		t.Error("la coupe a cassé un caractère")
	}
}

func TestNormalizePlaybackLogsHoldsTheByteCeiling(t *testing.T) {
	// Des lignes longues mais moins nombreuses que le plafond de lignes : c'est
	// le plafond d'octets qui doit mordre.
	fat := PlaybackLogLine{Message: strings.Repeat("x", playbackLogMaxLineLength)}
	in := make([]PlaybackLogLine, 200)
	for i := range in {
		in[i] = fat
	}

	out, _ := normalizePlaybackLogLines(in)

	if len(out) >= 200 {
		t.Fatalf("le plafond d'octets n'a pas mordu : %d lignes gardées", len(out))
	}
	size := 0
	for _, line := range out {
		size += len(line.Message) + 64
	}
	if size > playbackLogMaxBytes {
		t.Errorf("stocké %d octets, plafond %d", size, playbackLogMaxBytes)
	}
}

func isValidUTF8(s string) bool {
	for _, r := range s {
		if r == '\uFFFD' {
			return false
		}
	}
	return true
}

func TestNormalizePlaybackStatsKeepsAnObject(t *testing.T) {
	out := normalizePlaybackStats([]byte(`{"average_fps": 23.9, "decoder": "nvdec"}`))
	if out == "" {
		t.Fatal("un résumé valide a été écarté")
	}
	if !strings.Contains(out, "average_fps") || !strings.Contains(out, "nvdec") {
		t.Fatalf("le contenu n'a pas survécu : %s", out)
	}
}

func TestNormalizePlaybackStatsRefusesWhatIsNotAnObject(t *testing.T) {
	// Ce qui sort d'ici est rendu tel quel à un administrateur : une chaîne, un
	// tableau ou du texte libre n'ont rien à y faire, quelle que soit leur
	// taille.
	for _, raw := range []string{`"nvdec"`, `[1,2,3]`, `12`, `pas du json`, `{}`, ``} {
		if out := normalizePlaybackStats([]byte(raw)); out != "" {
			t.Errorf("%q aurait dû être écarté, reçu %q", raw, out)
		}
	}
}

func TestNormalizePlaybackStatsHoldsTheByteCeiling(t *testing.T) {
	// Un objet bien formé mais démesuré : le plafond mord avant l'analyse, pour
	// qu'un client bavard ne fasse pas allouer la mémoire qu'il demande.
	big := `{"note": "` + strings.Repeat("x", playbackStatsMaxBytes) + `"}`
	if out := normalizePlaybackStats([]byte(big)); out != "" {
		t.Fatalf("le plafond n'a pas mordu : %d octets gardés", len(out))
	}
}

func postLogs(t *testing.T, token string, payload map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	router := httprouter.New()
	router.POST("/api/playing/logs", RequireAuth(AttachPlaybackLogs))
	body, _ := json.Marshal(payload)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, bearerRequest(http.MethodPost, "/api/playing/logs", token, body))
	return rec
}

func countLogs(t *testing.T) int {
	t.Helper()
	var n int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM playback_logs`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestPlaybackLogsReachTheRowAfterTheSessionClosed(t *testing.T) {
	// Une app tuée envoie son journal au lancement suivant, quand la séance a
	// été fermée par le balayage : l'identifiant appris à l'envoi précédent doit
	// suffire à retrouver la lecture.
	fx := setupActivityTestDB(t)
	insertSession(t, "lea-tv", 3)
	key := sessionKey("lea-tv")
	if err := playbackActivity.report(key, 3, "lea", sessionClient{device: "Salon"}, PlaybackReport{
		MediaID: fx.movieID, Event: "start", Duration: 9000, PlayMethod: "direct",
	}); err != nil {
		t.Fatal(err)
	}
	// Assez longue pour survivre à la règle des trente secondes à la fermeture.
	for i := 1; i <= 4; i++ {
		fx.advance(15 * time.Second)
		if err := playbackActivity.report(key, 3, "lea", sessionClient{device: "Salon"}, PlaybackReport{
			MediaID: fx.movieID, Event: "progress", Position: i * 15, Duration: 9000, PlayMethod: "direct",
		}); err != nil {
			t.Fatal(err)
		}
	}
	line := []map[string]any{{"at": "2026-09-14T20:00:00Z", "level": "info", "message": "premier envoi"}}

	rec := postLogs(t, "lea-tv", map[string]any{"lines": line})
	var first struct {
		HistoryID int64 `json:"history_id"`
	}
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &first) != nil || first.HistoryID == 0 {
		t.Fatalf("premier envoi : %d %s", rec.Code, rec.Body)
	}

	playbackActivity.dropSession(key)
	line[0]["message"] = "envoi rejoué"
	rec = postLogs(t, "lea-tv", map[string]any{"lines": line, "history_id": first.HistoryID})
	if rec.Code != http.StatusOK {
		t.Fatalf("envoi rejoué : %d %s", rec.Code, rec.Body)
	}
	var body string
	if err := database.DB.QueryRow(`SELECT body FROM playback_logs WHERE history_id = ?`, first.HistoryID).Scan(&body); err != nil || !strings.Contains(body, "envoi rejoué") {
		t.Fatalf("le journal rejoué n'a pas remplacé le premier : %q (%v)", body, err)
	}
}

func TestPlaybackLogsRefuseAnotherAccountsHistoryRow(t *testing.T) {
	fx := setupActivityTestDB(t)
	insertSession(t, "lea-tv", 3)
	res, err := database.DB.Exec(`INSERT INTO playback_history (user_id, media_id, media_type, title, started_at, ended_at, watched_seconds)
		VALUES (1, ?, 'movie', 'Dune', ?, ?, 600)`, fx.movieID, historyStamp(fx.clock), historyStamp(fx.clock))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()

	rec := postLogs(t, "lea-tv", map[string]any{
		"lines":      []map[string]any{{"level": "info", "message": "intrus"}},
		"history_id": id,
	})
	if rec.Code != http.StatusNoContent || countLogs(t) != 0 {
		t.Fatalf("la lecture d'un autre compte a reçu un journal : %d, %d lignes", rec.Code, countLogs(t))
	}
}

func TestPlaybackLogsKeepTheFiftyNewestPlays(t *testing.T) {
	setupActivityTestDB(t)
	for i := 1; i <= playbackLogMaxRows+5; i++ {
		res, err := database.DB.Exec(`INSERT INTO playback_history (user_id, media_type, title, started_at, ended_at, watched_seconds)
			VALUES (3, 'movie', 'Dune', ?, ?, 600)`, historyStamp(time.Now()), historyStamp(time.Now()))
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		if _, err := database.DB.Exec(`INSERT INTO playback_logs (history_id, has_error, line_count, body, stats, updated_at) VALUES (?, 0, 0, '[]', '', ?)`, id, historyStamp(time.Now())); err != nil {
			t.Fatal(err)
		}
	}
	pruneOldPlaybackLogs()
	if got := countLogs(t); got != playbackLogMaxRows || playbackLogMaxRows != 50 {
		t.Fatalf("%d journaux gardés, attendu %d (50)", got, playbackLogMaxRows)
	}
}
