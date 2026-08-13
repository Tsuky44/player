package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// InvitationTTL is how long a freshly generated link stays redeemable. Fixed
// rather than configurable: a link travels through WhatsApp and survives in the
// history, so it should stop working on its own, and one week comfortably
// covers "I send it tonight, they sign up over the weekend".
const InvitationTTL = 7 * 24 * time.Hour

// Invitation is a single-use registration link.
type Invitation struct {
	Token     string             `json:"token"`
	InviterID int                `json:"inviter_id"`
	Inviter   string             `json:"inviter"`
	// Grants is frozen when the link is created: a link does exactly what it
	// announced, even if the inviter's template changes afterwards.
	Grants    models.Permissions `json:"grants"`
	Status    string             `json:"status"` // pending | used | revoked | expired
	CreatedAt time.Time          `json:"created_at"`
	ExpiresAt time.Time          `json:"expires_at"`
	UsedAt    *time.Time         `json:"used_at,omitempty"`
	UsedBy    string             `json:"used_by,omitempty"`
}

const invitationColumns = `i.token, i.inviter_id, COALESCE(u.username, ''), i.grants,
	i.status, i.created_at, i.expires_at, i.used_at, COALESCE(used.username, '')`

const invitationFrom = `FROM invitations i
	LEFT JOIN users u ON u.id = i.inviter_id
	LEFT JOIN users used ON used.id = i.used_by_user_id`

func scanInvitation(row rowScanner) (Invitation, error) {
	var inv Invitation
	var grants string
	var createdAt, expiresAt, usedAt sql.NullString
	err := row.Scan(
		&inv.Token, &inv.InviterID, &inv.Inviter, &grants,
		&inv.Status, &createdAt, &expiresAt, &usedAt, &inv.UsedBy,
	)
	if err != nil {
		return Invitation{}, err
	}
	inv.Grants = models.DecodePermissions(grants)
	inv.CreatedAt = scanSQLiteTime(createdAt)
	inv.ExpiresAt = scanSQLiteTime(expiresAt)
	if t := scanSQLiteTime(usedAt); !t.IsZero() {
		inv.UsedAt = &t
	}
	// Expiry is derived rather than stored: no sweeper job to run or to forget.
	if inv.Status == "pending" && !inv.ExpiresAt.IsZero() && time.Now().After(inv.ExpiresAt) {
		inv.Status = "expired"
	}
	return inv, nil
}

// redeemableInvitation returns the invitation for token when it can still be
// used, or nil when it is unknown, spent, revoked or expired.
func redeemableInvitation(token string) (*Invitation, error) {
	inv, err := scanInvitation(database.DB.QueryRow(
		"SELECT "+invitationColumns+" "+invitationFrom+" WHERE i.token = ?", token))
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	if inv.Status != "pending" {
		return nil, nil
	}
	return &inv, nil
}

func markInvitationUsed(token string, userID int) error {
	_, err := database.DB.Exec(
		`UPDATE invitations
		 SET status = 'used', used_at = CURRENT_TIMESTAMP, used_by_user_id = ?
		 WHERE token = ? AND status = 'pending'`, userID, token)
	return err
}

// revokePendingInvitations kills every link an inviter still has in
// circulation. Called when invite_users is taken away: revoking the right has
// to revoke what it already produced, otherwise it means nothing while the
// links are out there.
func revokePendingInvitations(inviterID int) error {
	_, err := database.DB.Exec(
		"UPDATE invitations SET status = 'revoked' WHERE inviter_id = ? AND status = 'pending'",
		inviterID)
	return err
}

// ListInvitations returns invitations (GET /api/invitations). Holding
// manage_users shows every link; holding only invite_users shows your own.
func ListInvitations(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("ListInvitations: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	query := "SELECT " + invitationColumns + " " + invitationFrom
	args := []any{}
	if !user.Permissions.ManageUsers {
		query += " WHERE i.inviter_id = ?"
		args = append(args, userID)
	}
	query += " ORDER BY i.created_at DESC"

	rows, err := database.DB.Query(query, args...)
	if err != nil {
		log.Printf("ListInvitations query error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer rows.Close()

	invitations := []Invitation{}
	for rows.Next() {
		inv, err := scanInvitation(rows)
		if err != nil {
			log.Printf("ListInvitations scan error: %v", err)
			continue
		}
		invitations = append(invitations, inv)
	}

	json.NewEncoder(w).Encode(invitations)
}

// CreateInvitation generates a single-use link (POST /api/invitations).
//
// The caller supplies nothing: the permissions come from the template an admin
// attached to their account. That is the whole point — an inviter cannot mint
// an admin account for themselves.
func CreateInvitation(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("CreateInvitation: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	grants := user.InviteGrants
	if user.Permissions.ManageUsers {
		// An admin can promote anyone after the fact, so letting them choose the
		// grants of their own links opens nothing new. Body is optional.
		var body struct {
			Grants *models.Permissions `json:"grants"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil && body.Grants != nil {
			grants = *body.Grants
		}
	}

	token, err := GenerateRandomToken()
	if err != nil {
		log.Printf("CreateInvitation: token generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	expiresAt := time.Now().UTC().Add(InvitationTTL)
	_, err = database.DB.Exec(
		`INSERT INTO invitations (token, inviter_id, grants, status, expires_at)
		 VALUES (?, ?, ?, 'pending', ?)`,
		token, userID, models.EncodePermissions(grants), expiresAt.Format(time.RFC3339))
	if err != nil {
		log.Printf("CreateInvitation insert error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(Invitation{
		Token:     token,
		InviterID: userID,
		Inviter:   user.Username,
		Grants:    grants,
		Status:    "pending",
		CreatedAt: time.Now().UTC(),
		ExpiresAt: expiresAt,
	})
}

// RevokeInvitation kills a pending link (DELETE /api/invitations/:token).
func RevokeInvitation(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	token := ps.ByName("token")

	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("RevokeInvitation: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	query := "UPDATE invitations SET status = 'revoked' WHERE token = ? AND status = 'pending'"
	args := []any{token}
	if !user.Permissions.ManageUsers {
		query += " AND inviter_id = ?"
		args = append(args, userID)
	}

	res, err := database.DB.Exec(query, args...)
	if err != nil {
		log.Printf("RevokeInvitation error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONError(w, http.StatusNotFound, "Invitation introuvable ou déjà consommée")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}
