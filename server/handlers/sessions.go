package handlers

import (
	"database/sql"
	"log"
	"strconv"
	"sync"
	"time"

	"project-player/server/database"
)

// Session lifetime.
//
// Tokens used to be valid forever: nothing ever read sessions.created_at, and
// nothing ever deleted a row, so a token leaked from an old phone stayed a
// working credential and the table only grew.
//
// The deadline is on inactivity rather than on age, because the alternative
// logs out a household TV mid-season for no security benefit. A session stays
// alive as long as it is used at least once every sessionIdleTTL.
const sessionIdleTTL = 90 * 24 * time.Hour

// sessionTouchInterval throttles the sliding-window write. Renewing on every
// authenticated request would put a write on the hot path of a pool that only
// holds four connections; renewing at most once every few hours keeps an active
// session alive just as reliably for one UPDATE per device per day.
const sessionTouchInterval = 6 * time.Hour

// sessionReaperInterval is how often expired rows are swept. Expiry is already
// enforced on read, so this only reclaims space — it can be lazy.
const sessionReaperInterval = 6 * time.Hour

// sqliteAge renders a duration as a SQLite modifier, e.g. "-2160 hours".
// Sessions are written with CURRENT_TIMESTAMP, so both sides of the comparison
// are 'YYYY-MM-DD HH:MM:SS' UTC and compare correctly as text.
func sqliteAge(d time.Duration) string {
	return "-" + strconv.Itoa(int(d.Hours())) + " hours"
}

// sqlExecer is what both *sql.DB and *sql.Tx offer for a write.
type sqlExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// storeSession opens a login session for userID under token. Only the
// token's digest is stored — see database.SessionTokenDigest — so every
// session is created here, and every lookup hashes what the client presents.
func storeSession(db sqlExecer, token string, userID int) error {
	_, err := db.Exec(`INSERT INTO sessions (token, user_id) VALUES (?, ?)`,
		database.SessionTokenDigest(token), userID)
	return err
}

// deleteSession closes the session a client holds token for.
func deleteSession(token string) error {
	digest := database.SessionTokenDigest(token)
	_, err := database.DB.Exec(`DELETE FROM sessions WHERE token = ?`, digest)
	forgetCachedSession(digest)
	return err
}

// Les sessions validées récemment, gardées en mémoire.
//
// Chaque requête authentifiée relisait sa session en base — l'affiche d'une
// grille, chaque battement du lecteur, chaque relevé d'une watch party — sur
// un pool de quatre connexions que l'indexeur occupe aussi. Une session vue il
// y a moins de sessionCacheTTL est reprise d'ici. Tout ce qui ferme une
// session l'efface aussitôt de ce cache : la déconnexion, la révocation d'un
// appareil, la réinitialisation d'un mot de passe, la suppression d'un compte.
// Ce qui expire seul (l'inactivité, 90 jours) ne peut pas être dans un cache
// de trente secondes.
const sessionCacheTTL = 30 * time.Second

// maxCachedSessions borne le cache ; au-delà, il repart de zéro.
const maxCachedSessions = 10_000

type cachedSession struct {
	userID int
	until  time.Time
}

var sessionCache = struct {
	sync.Mutex
	entries map[string]cachedSession
}{entries: map[string]cachedSession{}}

func cachedSessionUser(digest string) (int, bool) {
	sessionCache.Lock()
	defer sessionCache.Unlock()
	entry, ok := sessionCache.entries[digest]
	if !ok || !time.Now().Before(entry.until) {
		return 0, false
	}
	return entry.userID, true
}

func rememberSession(digest string, userID int) {
	sessionCache.Lock()
	defer sessionCache.Unlock()
	if len(sessionCache.entries) >= maxCachedSessions {
		sessionCache.entries = map[string]cachedSession{}
	}
	sessionCache.entries[digest] = cachedSession{userID: userID, until: time.Now().Add(sessionCacheTTL)}
}

func forgetCachedSession(digest string) {
	sessionCache.Lock()
	delete(sessionCache.entries, digest)
	sessionCache.Unlock()
}

// forgetCachedSessionsOf efface du cache toutes les sessions d'un compte.
func forgetCachedSessionsOf(userID int) {
	sessionCache.Lock()
	for digest, entry := range sessionCache.entries {
		if entry.userID == userID {
			delete(sessionCache.entries, digest)
		}
	}
	sessionCache.Unlock()
}

// deleteSessionsFor closes the sessions whose clear tokens selectTokens
// returns. The pairing and access-request tables still hold the clear token
// until the device collects it, while sessions only holds its digest, so the
// match has to be made here rather than in SQL.
func deleteSessionsFor(selectTokens string, args ...any) error {
	rows, err := database.DB.Query(selectTokens, args...)
	if err != nil {
		return err
	}
	var tokens []string
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			rows.Close()
			return err
		}
		tokens = append(tokens, token)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, token := range tokens {
		if err := deleteSession(token); err != nil {
			return err
		}
	}
	return nil
}

// lookupSession resolves a bearer token to its user, enforcing the idle
// deadline, and slides that deadline forward when the session has not been
// touched recently.
//
// Returns ok=false for both an unknown and an expired token: the client cannot
// tell them apart, and neither can an attacker probing for live tokens.
func lookupSession(token string) (userID int, ok bool, err error) {
	digest := database.SessionTokenDigest(token)
	if cached, hit := cachedSessionUser(digest); hit {
		return cached, true, nil
	}
	var staleSeen bool
	err = database.DB.QueryRow(`
		SELECT user_id,
		       COALESCE(last_seen_at, created_at) < datetime('now', ?)
		FROM sessions
		WHERE token = ?
		  AND COALESCE(last_seen_at, created_at) > datetime('now', ?)`,
		sqliteAge(sessionTouchInterval), digest, sqliteAge(sessionIdleTTL),
	).Scan(&userID, &staleSeen)
	if err != nil {
		return 0, false, err
	}

	if staleSeen {
		if _, updateErr := database.DB.Exec(
			`UPDATE sessions SET last_seen_at = CURRENT_TIMESTAMP WHERE token = ?`, digest,
		); updateErr != nil {
			// The session is valid either way; failing to slide the window only
			// means it expires earlier than it should.
			log.Printf("Session: failed to refresh last_seen_at: %v", updateErr)
		}
	}

	rememberSession(digest, userID)
	return userID, true, nil
}

// StartSessionReaper deletes expired sessions in the background. Call once at
// startup, after InitDB.
func StartSessionReaper() {
	go func() {
		for {
			purgeExpiredSessions()
			time.Sleep(sessionReaperInterval)
		}
	}()
}

func purgeExpiredSessions() {
	res, err := database.DB.Exec(
		`DELETE FROM sessions WHERE COALESCE(last_seen_at, created_at) <= datetime('now', ?)`,
		sqliteAge(sessionIdleTTL),
	)
	if err != nil {
		log.Printf("Session reaper: %v", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		log.Printf("Session reaper: removed %d expired session(s)", n)
	}
}
