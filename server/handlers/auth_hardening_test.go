package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
	"golang.org/x/crypto/bcrypt"
)

// Phase de durcissement de l'authentification : ce que la base garde d'un
// jeton, la course à l'inscription, et le rythme des essais.

func TestSessionTokensAreStoredOnlyAsDigests(t *testing.T) {
	setupAuthDB(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("secret"), bcrypt.MinCost)
	if _, err := database.DB.Exec(`INSERT INTO users (username, password_hash) VALUES ('lea', ?)`, string(hash)); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	Login(rec, httptest.NewRequest(http.MethodPost, "/api/auth/login",
		strings.NewReader(`{"username":"lea","password":"secret"}`)), nil)
	var resp LoginResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil || resp.Token == "" {
		t.Fatalf("login: %d %v", rec.Code, err)
	}

	var stored string
	if err := database.DB.QueryRow(`SELECT token FROM sessions`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == resp.Token {
		t.Fatal("a copy of the database must not be enough to sign in")
	}

	// Le jeton que l'appareil détient reste celui qui ouvre la session.
	called := false
	RequireAuth(okHandler(&called))(httptest.NewRecorder(),
		authedRequest(http.MethodGet, "/api/auth/me", "", resp.Token), nil)
	if !called {
		t.Fatal("the token handed to the client must still authenticate")
	}

	// Et la déconnexion ferme bien cette session-là.
	Logout(httptest.NewRecorder(), authedRequest(http.MethodPost, "/api/auth/logout", "", resp.Token), nil)
	var left int
	database.DB.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&left)
	if left != 0 {
		t.Errorf("%d session(s) left after logout", left)
	}
}

func TestOnlyOneOwnerWhenTwoSignUpsRaceOnAPristineServer(t *testing.T) {
	setupAuthDB(t)

	// Les deux ont vu une table vide : c'est l'écriture qui doit trancher.
	_, first, _ := insertRegisteredUser("a", "x", true, models.AllPermissions(), nil)
	_, second, _ := insertRegisteredUser("b", "x", true, models.AllPermissions(), nil)
	if first != 0 {
		t.Fatalf("the first account must be created, got status %d", first)
	}
	if second != http.StatusForbidden {
		t.Fatalf("the second owner must be refused, got status %d", second)
	}
	var owners int
	database.DB.QueryRow(`SELECT COUNT(*) FROM users WHERE is_owner = 1`).Scan(&owners)
	if owners != 1 {
		t.Errorf("%d owners, want 1", owners)
	}
}

func TestAnInvitationOpensOneAccountEvenUnderARace(t *testing.T) {
	setupAuthDB(t)
	inviter := createTestUser(t, "owner", true, models.AllPermissions())
	if _, err := database.DB.Exec(
		`INSERT INTO invitations (token, inviter_id, grants, status, expires_at) VALUES ('inv', ?, '', 'pending', ?)`,
		inviter, time.Now().Add(time.Hour).Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	invitation, err := redeemableInvitation("inv")
	if err != nil || invitation == nil {
		t.Fatalf("invitation: %v", err)
	}

	// Deux inscriptions qui ont toutes deux trouvé le lien valide.
	var wg sync.WaitGroup
	statuses := make([]int, 2)
	for i, name := range []string{"x", "y"} {
		wg.Add(1)
		go func(i int, name string) {
			defer wg.Done()
			_, statuses[i], _ = insertRegisteredUser(name, "x", false, models.DefaultPermissions(), invitation)
		}(i, name)
	}
	wg.Wait()

	succeeded := 0
	for _, s := range statuses {
		if s == 0 {
			succeeded++
		}
	}
	var accounts int
	database.DB.QueryRow(`SELECT COUNT(*) FROM users WHERE username IN ('x', 'y')`).Scan(&accounts)
	if succeeded != 1 || accounts != 1 {
		t.Fatalf("a single-use link opened %d account(s) (statuses %v)", accounts, statuses)
	}
}

func TestRateLimiter_RefillsAtItsPace(t *testing.T) {
	now := time.Unix(0, 0)
	l := newRateLimiter(2, 10*time.Second)
	l.now = func() time.Time { return now }

	for i := 0; i < 2; i++ {
		if ok, _ := l.allow("ip"); !ok {
			t.Fatalf("attempt %d within the burst was refused", i+1)
		}
	}
	ok, wait := l.allow("ip")
	if ok || wait <= 0 || wait > 10*time.Second {
		t.Fatalf("third attempt: ok=%v wait=%v, want refused with a wait", ok, wait)
	}
	if ok, _ := l.allow("other"); !ok {
		t.Fatal("another address has its own bucket")
	}

	now = now.Add(10 * time.Second)
	if ok, _ := l.allow("ip"); !ok {
		t.Fatal("a token must come back after the refill period")
	}
}

func TestRateLimited_AnswersTooManyRequests(t *testing.T) {
	calls := 0
	handler := RateLimited(newRateLimiter(1, time.Hour), func(http.ResponseWriter, *http.Request, httprouter.Params) {
		calls++
	})
	request := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/auth/login", nil)
		req.RemoteAddr = "203.0.113.7:4242"
		handler(rec, req, nil)
		return rec
	}
	request()
	rec := request()
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" || calls != 1 {
		t.Fatalf("status %d, Retry-After %q, calls %d", rec.Code, rec.Header().Get("Retry-After"), calls)
	}
}

func TestRateLimitKey_TrustsOnlyTheProxysOwnEntry(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/", nil)

	// Depuis Internet, sans proxy : l'en-tête est écrit par le client, ignoré.
	req.RemoteAddr = "203.0.113.7:4242"
	req.Header.Set("X-Forwarded-For", "198.51.100.1")
	if got := rateLimitKey(req); got != "203.0.113.7" {
		t.Errorf("direct client: key %q", got)
	}

	// Derrière un proxy local : la dernière entrée, celle qu'il a ajoutée. La
	// première, le client l'a forgée.
	req.RemoteAddr = "127.0.0.1:4242"
	req.Header.Set("X-Forwarded-For", "10.9.9.9, 198.51.100.1")
	if got := rateLimitKey(req); got != "198.51.100.1" {
		t.Errorf("behind a proxy: key %q", got)
	}
}

func TestLoginStopsAfterTooManyFailuresOnOneAccount(t *testing.T) {
	setupAuthDB(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("secret"), bcrypt.MinCost)
	if _, err := database.DB.Exec(`INSERT INTO users (username, password_hash) VALUES ('cible', ?)`, string(hash)); err != nil {
		t.Fatal(err)
	}
	saved := accountLoginLimiter
	t.Cleanup(func() { accountLoginLimiter = saved })
	accountLoginLimiter = newRateLimiter(3, time.Hour)

	login := func(password string) int {
		rec := httptest.NewRecorder()
		Login(rec, httptest.NewRequest(http.MethodPost, "/api/auth/login",
			strings.NewReader(`{"username":"cible","password":"`+password+`"}`)), nil)
		return rec.Code
	}
	for i := 0; i < 3; i++ {
		if code := login("faux"); code != http.StatusUnauthorized {
			t.Fatalf("failure %d: status %d", i+1, code)
		}
	}
	// Les essais répartis sur plusieurs adresses s'additionnent ici : même le
	// bon mot de passe attend que le seau se remplisse.
	if code := login("secret"); code != http.StatusTooManyRequests {
		t.Fatalf("after the budget: status %d, want 429", code)
	}
}

func TestOnlyAnActivePlayerFillsInAMissingDuration(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "lea", false, models.DefaultPermissions())
	res, err := database.DB.Exec(`INSERT INTO medias (type, title, file_path, duration) VALUES ('movie', 'Film', '/m/film.mkv', 0)`)
	if err != nil {
		t.Fatal(err)
	}
	mediaID, _ := res.LastInsertId()
	body := `{"media_id":` + strconv.FormatInt(mediaID, 10) + `,"current_position_seconds":60,"duration":5400}`
	stored := func() int {
		var d int
		database.DB.QueryRow(`SELECT duration FROM medias WHERE id = ?`, mediaID).Scan(&d)
		return d
	}

	UpdateProgress(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/progress", strings.NewReader(body)), nil, userID)
	if got := stored(); got != 0 {
		t.Fatalf("a client that is not playing wrote duration %d for everyone", got)
	}

	token, _, err := PlaybackTickets.Issue(userID, int(mediaID))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { PlaybackTickets.Revoke(token, userID) })
	UpdateProgress(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/progress", strings.NewReader(body)), nil, userID)
	if got := stored(); got != 5400 {
		t.Fatalf("the player's measured duration was not kept: %d", got)
	}
}

func TestAClosedSessionIsNotServedFromTheCache(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "lea", false, models.DefaultPermissions())
	token := createTestSession(t, userID)

	authenticates := func() bool {
		called := false
		RequireAuth(okHandler(&called))(httptest.NewRecorder(),
			authedRequest(http.MethodGet, "/api/auth/me", "", token), nil)
		return called
	}
	if !authenticates() || !authenticates() {
		t.Fatal("a live session must authenticate, cached or not")
	}

	// La réinitialisation du mot de passe ferme toutes les sessions du compte :
	// le cache ne doit pas en garder une trente secondes de plus.
	if _, err := database.DB.Exec("DELETE FROM sessions WHERE user_id = ?", userID); err != nil {
		t.Fatal(err)
	}
	forgetCachedSessionsOf(userID)
	if authenticates() {
		t.Fatal("a closed session was still accepted from the cache")
	}
}
