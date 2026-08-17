package handlers

// Administration rights.
//
// There is no role column: the server is a personal, single-household setup and
// the person who installed it is the one who created the first account. The
// admin is therefore simply the oldest user row — no migration to run, no way
// to end up with zero admins, and a fresh install has one as soon as somebody
// registers.

import (
	"log"
	"net/http"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// AdminUserID returns the id of the first registered account, or 0 when no user
// exists yet.
func AdminUserID() int {
	var id int
	if err := database.DB.QueryRow("SELECT id FROM users ORDER BY id LIMIT 1").Scan(&id); err != nil {
		return 0
	}
	return id
}

// IsAdmin reports whether userID owns the first registered account.
func IsAdmin(userID int) bool {
	adminID := AdminUserID()
	return adminID != 0 && adminID == userID
}

// RequireAdmin wraps RequireAuth and additionally rejects everyone but the
// first account.
func RequireAdmin(next AuthenticatedHandle) httprouter.Handle {
	return RequireAuth(func(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
		if !IsAdmin(userID) {
			log.Printf("Admin route %s refused for user %d", r.URL.Path, userID)
			writeJSONError(w, http.StatusForbidden, "Réservé au compte administrateur")
			return
		}
		next(w, r, ps, userID)
	})
}
