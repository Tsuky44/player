package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
	"golang.org/x/crypto/bcrypt"
)

// DeleteOwnAccountRequest is the body of POST /api/auth/account/delete.
type DeleteOwnAccountRequest struct {
	Password string `json:"password"`
}

// DeleteOwnAccount supprime le compte de l'appelant et, par cascade, tout ce
// qui lui appartient — comme DeleteUser, mais sans passer par un
// administrateur. Les magasins d'applications l'exigent de toute app où l'on
// peut créer un compte (ADR-0046).
//
// Le mot de passe est redemandé : un appareil déverrouillé oublié sur un
// canapé ne doit pas suffire. Le propriétaire est refusé, parce qu'un serveur
// sans propriétaire redeviendrait un serveur vierge dont le premier inscrit
// venu prendrait la tête ; il transfère d'abord la propriété.
func DeleteOwnAccount(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req DeleteOwnAccountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	var passwordHash string
	var isOwner bool
	if err := database.DB.QueryRow(
		"SELECT password_hash, is_owner FROM users WHERE id = ?", userID,
	).Scan(&passwordHash, &isOwner); err != nil {
		log.Printf("DeleteOwnAccount: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(req.Password)); err != nil {
		writeJSONError(w, http.StatusUnauthorized, "Mot de passe incorrect")
		return
	}
	if isOwner {
		writeJSONError(w, http.StatusForbidden,
			"Le propriétaire ne peut pas supprimer son compte. Transférez d'abord la propriété à un autre administrateur.")
		return
	}

	// Ses sessions partent avec lui (ON DELETE CASCADE) : le cache aussi.
	defer forgetCachedSessionsOf(userID)
	if _, err := database.DB.Exec("DELETE FROM users WHERE id = ?", userID); err != nil {
		log.Printf("DeleteOwnAccount: delete failed for %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}
