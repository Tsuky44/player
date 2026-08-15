package handlers

import (
	"log"
	"strconv"
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

// lookupSession resolves a bearer token to its user, enforcing the idle
// deadline, and slides that deadline forward when the session has not been
// touched recently.
//
// Returns ok=false for both an unknown and an expired token: the client cannot
// tell them apart, and neither can an attacker probing for live tokens.
func lookupSession(token string) (userID int, ok bool, err error) {
	var staleSeen bool
	err = database.DB.QueryRow(`
		SELECT user_id,
		       COALESCE(last_seen_at, created_at) < datetime('now', ?)
		FROM sessions
		WHERE token = ?
		  AND COALESCE(last_seen_at, created_at) > datetime('now', ?)`,
		sqliteAge(sessionTouchInterval), token, sqliteAge(sessionIdleTTL),
	).Scan(&userID, &staleSeen)
	if err != nil {
		return 0, false, err
	}

	if staleSeen {
		if _, updateErr := database.DB.Exec(
			`UPDATE sessions SET last_seen_at = CURRENT_TIMESTAMP WHERE token = ?`, token,
		); updateErr != nil {
			// The session is valid either way; failing to slide the window only
			// means it expires earlier than it should.
			log.Printf("Session: failed to refresh last_seen_at: %v", updateErr)
		}
	}

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
