package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

func readProgressRevision(t *testing.T, userID int) string {
	t.Helper()
	w := httptest.NewRecorder()
	GetProgressRevision(w, httptest.NewRequest("GET", "/api/progress/revision", nil), nil, userID)
	if w.Code != 200 {
		t.Fatalf("revision: %d %s", w.Code, w.Body.String())
	}
	var resp models.ProgressRevision
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode revision: %v", err)
	}
	return resp.Revision
}

// Un écran ouvert ne relit ses données que si le jeton a bougé : il doit donc
// bouger à chaque chose qu'un autre appareil peut faire, et rester immobile
// sinon — y compris quand c'est un autre compte qui regarde.
func TestProgressRevisionChangesWithWhatTheAccountWatched(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	if _, err := database.DB.Exec(
		"INSERT INTO users (id, username, password_hash) VALUES (2, 'other', 'hash')",
	); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	var episodeID, showID int
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE type = 'episode'").Scan(&episodeID); err != nil {
		t.Fatalf("find episode: %v", err)
	}
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE type = 'show'").Scan(&showID); err != nil {
		t.Fatalf("find show: %v", err)
	}
	post := func(userID int, handler AuthenticatedHandle, body interface{}) {
		t.Helper()
		raw, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		handler(w, httptest.NewRequest("POST", "/", bytes.NewReader(raw)), nil, userID)
		if w.Code != 200 {
			t.Fatalf("post: %d %s", w.Code, w.Body.String())
		}
	}

	start := readProgressRevision(t, 1)
	if again := readProgressRevision(t, 1); again != start {
		t.Fatalf("revision moved without a write: %q then %q", start, again)
	}

	post(1, UpdateProgress, ProgressRequest{MediaID: episodeID, CurrentPositionSeconds: 600, Duration: 2820})
	afterHeartbeat := readProgressRevision(t, 1)
	if afterHeartbeat == start {
		t.Fatal("a heartbeat from another device did not move the revision")
	}

	post(1, HideFromContinueWatching, map[string]int{"show_id": showID})
	afterHide := readProgressRevision(t, 1)
	if afterHide == afterHeartbeat {
		t.Fatal("hiding a continue-watching entry did not move the revision")
	}

	if _, err := database.DB.Exec("DELETE FROM progressions WHERE user_id = 1"); err != nil {
		t.Fatalf("delete progress: %v", err)
	}
	if afterDelete := readProgressRevision(t, 1); afterDelete == afterHide {
		t.Fatal("deleted progress did not move the revision")
	}

	otherStart := readProgressRevision(t, 2)
	post(1, UpdateProgress, ProgressRequest{MediaID: episodeID, CurrentPositionSeconds: 900, Duration: 2820})
	if got := readProgressRevision(t, 2); got != otherStart {
		t.Fatalf("another account's playback moved this revision: %q then %q", otherStart, got)
	}
}

// pollProgressRevision ouvre l'attente d'un écran et rend le canal où tombera
// sa réponse.
func pollProgressRevision(ctx context.Context, userID int, since string) <-chan string {
	answer := make(chan string, 1)
	go func() {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/api/progress/revision?since="+url.QueryEscape(since), nil)
		GetProgressRevision(w, r.WithContext(ctx), nil, userID)
		var resp models.ProgressRevision
		_ = json.Unmarshal(w.Body.Bytes(), &resp)
		answer <- resp.Revision
	}()
	return answer
}

// L'écran qui attend avec le jeton courant ne reçoit rien tant que rien ne
// bouge, puis sa réponse à l'instant où un autre appareil écrit — sans
// attendre la relecture de secours ni la fin de la fenêtre.
func TestProgressRevisionLongPollWakesOnWrite(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	window, recheck := progressRevisionPollWindow, progressRevisionRecheck
	progressRevisionPollWindow, progressRevisionRecheck = time.Minute, time.Minute
	defer func() { progressRevisionPollWindow, progressRevisionRecheck = window, recheck }()

	var episodeID int
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE type = 'episode'").Scan(&episodeID); err != nil {
		t.Fatalf("find episode: %v", err)
	}
	start := readProgressRevision(t, 1)
	answer := pollProgressRevision(context.Background(), 1, start)

	select {
	case got := <-answer:
		t.Fatalf("answered %q before anything changed", got)
	case <-time.After(150 * time.Millisecond):
	}

	raw, _ := json.Marshal(ProgressRequest{MediaID: episodeID, CurrentPositionSeconds: 600, Duration: 2820})
	w := httptest.NewRecorder()
	NotifiesProgress(UpdateProgress)(w, httptest.NewRequest("POST", "/api/progress", bytes.NewReader(raw)), nil, 1)
	if w.Code != 200 {
		t.Fatalf("heartbeat: %d %s", w.Code, w.Body.String())
	}

	select {
	case got := <-answer:
		if got == "" || got == start {
			t.Fatalf("woke up with %q, started from %q", got, start)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the waiting screen was not woken by the heartbeat")
	}
}

// Une écriture faite hors des routes du compte (import d'un serveur lié,
// Emby) ne réveille personne : la relecture de secours doit la rattraper.
func TestProgressRevisionLongPollCatchesBackgroundWrites(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	window, recheck := progressRevisionPollWindow, progressRevisionRecheck
	progressRevisionPollWindow, progressRevisionRecheck = time.Minute, 20*time.Millisecond
	defer func() { progressRevisionPollWindow, progressRevisionRecheck = window, recheck }()

	start := readProgressRevision(t, 1)
	answer := pollProgressRevision(context.Background(), 1, start)
	if _, err := database.DB.Exec("UPDATE progressions SET current_position_seconds = 999 WHERE user_id = 1"); err != nil {
		t.Fatalf("background write: %v", err)
	}
	select {
	case got := <-answer:
		if got == "" || got == start {
			t.Fatalf("answered %q, started from %q", got, start)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a background write never reached the waiting screen")
	}
}

// Rien ne bouge : la fenêtre se referme sur le même jeton, et l'écran qui
// s'en va libère sa requête sans attendre la fin.
func TestProgressRevisionLongPollEndsOnWindowAndDisconnect(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	window, recheck := progressRevisionPollWindow, progressRevisionRecheck
	defer func() { progressRevisionPollWindow, progressRevisionRecheck = window, recheck }()
	start := readProgressRevision(t, 1)

	progressRevisionPollWindow, progressRevisionRecheck = 50*time.Millisecond, time.Minute
	select {
	case got := <-pollProgressRevision(context.Background(), 1, start):
		if got != start {
			t.Fatalf("an idle window answered %q, expected the unchanged %q", got, start)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the window never closed")
	}

	progressRevisionPollWindow = time.Minute
	ctx, cancel := context.WithCancel(context.Background())
	answer := pollProgressRevision(ctx, 1, start)
	cancel()
	select {
	case <-answer:
	case <-time.After(5 * time.Second):
		t.Fatal("a disconnected screen kept its request open")
	}
}

// Un écran en attente tenait l'arrêt du serveur jusqu'à sa fermeture forcée,
// cinq secondes plus tard : l'arrêt doit lui répondre tout de suite.
func TestProgressRevisionLongPollEndsOnShutdown(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	window, recheck, watchers := progressRevisionPollWindow, progressRevisionRecheck, ProgressWatchers
	progressRevisionPollWindow, progressRevisionRecheck = time.Minute, time.Minute
	ProgressWatchers = newProgressWatchers()
	defer func() {
		progressRevisionPollWindow, progressRevisionRecheck, ProgressWatchers = window, recheck, watchers
	}()

	start := readProgressRevision(t, 1)
	answer := pollProgressRevision(context.Background(), 1, start)
	select {
	case got := <-answer:
		t.Fatalf("answered %q before the shutdown", got)
	case <-time.After(100 * time.Millisecond):
	}

	ProgressWatchers.Shutdown()
	select {
	case got := <-answer:
		if got != start {
			t.Fatalf("shutdown answered %q, expected the unchanged %q", got, start)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a waiting screen held the shutdown open")
	}
}

// Un animé de 24 min dont le générique commence à 20 min 30 : le battement
// envoyé dedans, à 86 %, doit suffire à le compter comme vu — sans attendre
// que l'app le dise en quittant proprement le lecteur.
func TestReachedCreditsCountsAnEpisodeLeftInItsOutro(t *testing.T) {
	cases := []struct {
		name                      string
		position, outro, duration int
		want                      bool
	}{
		{"dans le générique", 1235, 1230, 1440, true},
		{"juste avant le générique", 1229, 1230, 1440, false},
		{"pas de générique détecté", 1235, 0, 1440, false},
		{"durée inconnue", 1235, 1230, 0, false},
		// Une fausse détection au milieu de l'épisode ne décide de rien.
		{"marqueur sous le plancher", 600, 580, 1440, false},
	}
	for _, c := range cases {
		if got := reachedCredits(c.position, c.outro, c.duration); got != c.want {
			t.Errorf("%s: reachedCredits(%d, %d, %d) = %v, want %v",
				c.name, c.position, c.outro, c.duration, got, c.want)
		}
	}
}
