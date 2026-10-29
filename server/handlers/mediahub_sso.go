package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"project-player/server/config"
	"project-player/server/httpx"
	"project-player/server/mediahub"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Ouvrir MediaHub déjà connecté depuis l'app (ADR-0088). Le format est
// épinglé par contract/mediahub/sso_*.json.

// mediaHubSSOCodes : les codes tirés et pas encore rachetés. En mémoire : un
// redémarrage d'Onyx ne coûte qu'un nouveau clic sur « Ouvrir MediaHub ».
var mediaHubSSOCodes = mediahub.NewSSOCodes(mediahub.SSOTTL, mediahub.SSOMaxPending)

// errSSOCodeGone : MediaHub reprend la connexion par son propre formulaire.
const errSSOCodeGone = "Code de connexion expiré ou déjà utilisé"

// SSORedeemResponse est la réponse au rachat : le compte, tel que
// /api/auth/me le décrit.
type SSORedeemResponse struct {
	User models.User `json:"user"`
}

// IssueMediaHubSSO tire un code pour le compte connecté
// (POST /api/integrations/mediahub/sso) et rend l'adresse de MediaHub où
// l'app envoie le navigateur.
func IssueMediaHubSSO(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	hub := mediaHubClient(httpx.Fast)
	if !hub.Configured() {
		writeMediaHubError(w, http.StatusServiceUnavailable, "MediaHub n'est pas configuré sur ce serveur")
		return
	}
	// OnyxHub n'a pas de route d'atterrissage. Une adresse muette n'empêche
	// rien : le rachat passe dans l'autre sens, de MediaHub vers Onyx.
	if hub.Dialect(r.Context()) == mediahub.DialectOnyxHub {
		writeMediaHubError(w, http.StatusNotImplemented, "Le compagnon de demandes de ce serveur ne le permet pas")
		return
	}

	code, err := mediaHubSSOCodes.Issue(userID)
	if err != nil {
		log.Printf("IssueMediaHubSSO: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(mediahub.SSOTicket{
		URL:       mediahub.SSOURL(config.MediaHubURL(), code),
		ExpiresIn: int(mediahub.SSOTTL.Seconds()),
	})
}

// RedeemMediaHubSSO échange un code contre le compte qui l'a tiré
// (POST /api/integrations/mediahub/sso/redeem). Sans session : c'est le
// serveur MediaHub qui appelle, avec la clé d'intégration. Seul lui peut donc
// apprendre à qui appartient un code, même lu dans un historique.
func RedeemMediaHubSSO(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	if err := mediahub.VerifyKey(r.Header, config.MediaHubAPIKey()); err != nil {
		writeJSONError(w, http.StatusUnauthorized, "Clé d'intégration invalide")
		return
	}
	var req mediahub.SSORedeemRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil || req.Code == "" {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	userID, ok := mediaHubSSOCodes.Redeem(req.Code)
	if !ok {
		writeJSONError(w, http.StatusGone, errSSOCodeGone)
		return
	}
	user, err := LoadUser(userID)
	if errors.Is(err, sql.ErrNoRows) {
		// Le compte a été supprimé entre le clic et le rachat.
		writeJSONError(w, http.StatusGone, errSSOCodeGone)
		return
	}
	if err != nil {
		log.Printf("RedeemMediaHubSSO: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(SSORedeemResponse{User: user})
}
