package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// userColumns is the projection used everywhere a full user is loaded, so the
// scan order in scanUser stays in one place.
const userColumns = `id, username, is_owner,
	perm_manage_settings, perm_manage_library, perm_manage_users,
	perm_delete_media, perm_invite_users, perm_request_media, invite_grants`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanUser(row rowScanner) (models.User, error) {
	var u models.User
	var grants string
	err := row.Scan(
		&u.ID, &u.Username, &u.IsOwner,
		&u.Permissions.ManageSettings, &u.Permissions.ManageLibrary, &u.Permissions.ManageUsers,
		&u.Permissions.DeleteMedia, &u.Permissions.InviteUsers, &u.Permissions.RequestMedia,
		&grants,
	)
	if err != nil {
		return models.User{}, err
	}
	u.InviteGrants = models.DecodePermissions(grants)
	return u, nil
}

// LoadUser reads a full user (permissions included) by id.
func LoadUser(userID int) (models.User, error) {
	return scanUser(database.DB.QueryRow(
		"SELECT "+userColumns+" FROM users WHERE id = ?", userID))
}

// CountAdmins counts accounts holding manage_users, the right that can hand out
// every other right. Used to enforce "never fewer than one admin".
func CountAdmins() (int, error) {
	var n int
	err := database.DB.QueryRow(
		"SELECT COUNT(*) FROM users WHERE perm_manage_users = 1").Scan(&n)
	return n, err
}

// RequirePermission wraps RequireAuth and rejects the request unless the caller
// holds perm. The Flutter client hides what a user may not do, but that is
// comfort only — this is the guard that actually holds, for curl as much as for
// a patched client.
func RequirePermission(perm models.Permission, next AuthenticatedHandle) httprouter.Handle {
	return RequireAnyPermission([]models.Permission{perm}, next)
}

// RequireAnyPermission passes when the caller holds at least one of perms. Used
// where two different rights legitimately open the same route — listing
// invitations is reachable both as an inviter and as an administrator.
func RequireAnyPermission(perms []models.Permission, next AuthenticatedHandle) httprouter.Handle {
	return RequireAuth(func(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
		user, err := LoadUser(userID)
		if err != nil {
			if err == sql.ErrNoRows {
				writeJSONError(w, http.StatusUnauthorized, "Invalid or expired session")
				return
			}
			log.Printf("RequirePermission load user %d: %v", userID, err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}

		granted := false
		for _, perm := range perms {
			if user.Permissions.Has(perm) {
				granted = true
				break
			}
		}
		if !granted {
			missing := make([]string, 0, len(perms))
			for _, perm := range perms {
				missing = append(missing, string(perm))
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			json.NewEncoder(w).Encode(map[string]any{
				"error":               "Droits insuffisants",
				"missing_permissions": missing,
			})
			return
		}

		next(w, r, ps, userID)
	})
}
