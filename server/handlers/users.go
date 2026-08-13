package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// ListUsers returns every account with its rights (GET /api/users).
func ListUsers(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	rows, err := database.DB.Query("SELECT " + userColumns + " FROM users ORDER BY id")
	if err != nil {
		log.Printf("ListUsers query error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer rows.Close()

	users := []models.User{}
	for rows.Next() {
		user, err := scanUser(rows)
		if err != nil {
			log.Printf("ListUsers scan error: %v", err)
			continue
		}
		users = append(users, user)
	}

	json.NewEncoder(w).Encode(users)
}

// loadTarget resolves the :id route param and loads that account.
func loadTarget(w http.ResponseWriter, ps httprouter.Params) (models.User, bool) {
	targetID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Identifiant utilisateur invalide")
		return models.User{}, false
	}

	target, err := LoadUser(targetID)
	if err != nil {
		if err == sql.ErrNoRows {
			writeJSONError(w, http.StatusNotFound, "Utilisateur introuvable")
		} else {
			log.Printf("loadTarget %d: %v", targetID, err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		}
		return models.User{}, false
	}
	return target, true
}

// UpdateUserPermissionsRequest is the body of PUT /api/users/:id/permissions.
// InviteGrants is the template the target's own invitation links will apply.
type UpdateUserPermissionsRequest struct {
	Permissions  models.Permissions  `json:"permissions"`
	InviteGrants *models.Permissions `json:"invite_grants"`
}

// UpdateUserPermissions rewrites a user's rights.
//
// Two invariants are enforced here rather than in the UI, because the UI is not
// a guard: the owner is untouchable by anyone but themselves, and the server
// never ends up with zero accounts able to administer it.
func UpdateUserPermissions(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	target, ok := loadTarget(w, ps)
	if !ok {
		return
	}

	caller, err := LoadUser(userID)
	if err != nil {
		log.Printf("UpdateUserPermissions: failed to load caller %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if target.IsOwner && !caller.IsOwner {
		writeJSONError(w, http.StatusForbidden, "Les droits du propriétaire ne peuvent pas être modifiés")
		return
	}

	var req UpdateUserPermissionsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	// Backstop below the owner rule: a non-owner admin may still be demoted, but
	// not the last one standing.
	if target.Permissions.ManageUsers && !req.Permissions.ManageUsers {
		admins, err := CountAdmins()
		if err != nil {
			log.Printf("UpdateUserPermissions: admin count failed: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		if admins <= 1 {
			writeJSONError(w, http.StatusBadRequest, "Il doit rester au moins un administrateur")
			return
		}
	}

	inviteGrants := target.InviteGrants
	if req.InviteGrants != nil {
		inviteGrants = *req.InviteGrants
	}
	if !req.Permissions.InviteUsers {
		// No point keeping a template for someone who cannot invite.
		inviteGrants = models.Permissions{}
	}

	_, err = database.DB.Exec(
		`UPDATE users SET
			perm_manage_settings = ?, perm_manage_library = ?, perm_manage_users = ?,
			perm_delete_media = ?, perm_invite_users = ?, perm_request_media = ?,
			invite_grants = ?
		 WHERE id = ?`,
		req.Permissions.ManageSettings, req.Permissions.ManageLibrary, req.Permissions.ManageUsers,
		req.Permissions.DeleteMedia, req.Permissions.InviteUsers, req.Permissions.RequestMedia,
		models.EncodePermissions(inviteGrants), target.ID,
	)
	if err != nil {
		log.Printf("UpdateUserPermissions update error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// Losing the right to invite also kills the links already in circulation.
	// Editing the template alone does not: that would silently break a legitimate
	// invitation someone is waiting on.
	if target.Permissions.InviteUsers && !req.Permissions.InviteUsers {
		if err := revokePendingInvitations(target.ID); err != nil {
			log.Printf("UpdateUserPermissions: failed to revoke invitations of %d: %v", target.ID, err)
		}
	}

	updated, err := LoadUser(target.ID)
	if err != nil {
		log.Printf("UpdateUserPermissions: reload failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(updated)
}

// ResetUserPasswordRequest is the body of POST /api/users/:id/password.
type ResetUserPasswordRequest struct {
	NewPassword string `json:"new_password"`
}

// ResetUserPassword sets another account's password. Without this, a forgotten
// password means hand-writing a bcrypt hash into SQLite.
func ResetUserPassword(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	target, ok := loadTarget(w, ps)
	if !ok {
		return
	}

	caller, err := LoadUser(userID)
	if err != nil {
		log.Printf("ResetUserPassword: failed to load caller %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if target.IsOwner && !caller.IsOwner {
		writeJSONError(w, http.StatusForbidden, "Le mot de passe du propriétaire ne peut pas être réinitialisé")
		return
	}

	var req ResetUserPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if len(req.NewPassword) < 4 {
		writeJSONError(w, http.StatusBadRequest, "Le mot de passe doit faire au moins 4 caractères")
		return
	}

	if err := setUserPassword(target.ID, req.NewPassword); err != nil {
		log.Printf("ResetUserPassword: update failed for %d: %v", target.ID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// A reset is a recovery, so every existing session of that account dies with
	// it — otherwise taking back a compromised account achieves nothing.
	if _, err := database.DB.Exec("DELETE FROM sessions WHERE user_id = ?", target.ID); err != nil {
		log.Printf("ResetUserPassword: failed to clear sessions of %d: %v", target.ID, err)
	}

	w.Write([]byte(`{"status": "success"}`))
}

// DeleteUser removes an account and, by foreign-key cascade, everything it
// owned: progressions, hidden entries, player layouts, sessions, invitations.
func DeleteUser(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	target, ok := loadTarget(w, ps)
	if !ok {
		return
	}

	if target.IsOwner {
		writeJSONError(w, http.StatusForbidden, "Le propriétaire ne peut pas être supprimé")
		return
	}
	if target.ID == userID {
		// Guard against the fatal click, not against malice.
		writeJSONError(w, http.StatusBadRequest, "Vous ne pouvez pas supprimer votre propre compte")
		return
	}
	if target.Permissions.ManageUsers {
		admins, err := CountAdmins()
		if err != nil {
			log.Printf("DeleteUser: admin count failed: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		if admins <= 1 {
			writeJSONError(w, http.StatusBadRequest, "Il doit rester au moins un administrateur")
			return
		}
	}

	if _, err := database.DB.Exec("DELETE FROM users WHERE id = ?", target.ID); err != nil {
		log.Printf("DeleteUser: delete failed for %d: %v", target.ID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}

// TransferOwnership hands the owner status to another administrator
// (POST /api/users/:id/transfer-ownership). Only the current owner may call it,
// and there is exactly one owner at any time.
func TransferOwnership(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	caller, err := LoadUser(userID)
	if err != nil {
		log.Printf("TransferOwnership: failed to load caller %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if !caller.IsOwner {
		writeJSONError(w, http.StatusForbidden, "Seul le propriétaire peut transférer la propriété")
		return
	}

	target, ok := loadTarget(w, ps)
	if !ok {
		return
	}
	if target.ID == caller.ID {
		writeJSONError(w, http.StatusBadRequest, "Vous êtes déjà propriétaire")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("TransferOwnership: begin failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec("UPDATE users SET is_owner = 0 WHERE id = ?", caller.ID); err != nil {
		log.Printf("TransferOwnership: demote failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	// The new owner gets every right along with the status: an owner who cannot
	// administer the server would be a dead end.
	if _, err := tx.Exec(
		`UPDATE users SET is_owner = 1,
			perm_manage_settings = 1, perm_manage_library = 1, perm_manage_users = 1,
			perm_delete_media = 1, perm_invite_users = 1, perm_request_media = 1
		 WHERE id = ?`, target.ID); err != nil {
		log.Printf("TransferOwnership: promote failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if err := tx.Commit(); err != nil {
		log.Printf("TransferOwnership: commit failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}
