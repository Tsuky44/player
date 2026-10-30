package handlers

import (
	"encoding/json"
	"net/http"

	"project-player/server/mediahub"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Ce que l'API v1 de MediaHub ajoute aux demandes (ADR-0089) : les droits du
// compte, la liste de tous les comptes et la modération. MediaHub juge chaque
// droit d'après le rôle du compte qui porte le même nom ; Onyx exige en plus
// manage_settings pour lire tout le monde et modérer (main.go).

// MediaHubRequestAccess dit ce que le compte peut faire chez le compagnon
// (GET /api/requests/access) : l'app n'affiche « Toutes les demandes » et
// les boutons de modération que si MediaHub les accorde.
func MediaHubRequestAccess(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	access, err := mediaHubClient(mediaHubHTTPClient).Access(r.Context(), account)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubRequestAccess", err)
		return
	}
	// La recherche interactive déclenche un téléchargement : Onyx la réserve à
	// manage_settings (main.go), l'app ne la propose donc qu'à qui l'a (ADR-0098).
	if access.Can.InteractiveSearch {
		user, err := LoadUser(userID)
		access.Can.InteractiveSearch = err == nil && user.Permissions.Has(models.PermManageSettings)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(access)
}

// MediaHubAllRequests rend les demandes de tous les comptes, en lots
// (GET /api/requests/all). MediaHub exige read MediaRequest.
func MediaHubAllRequests(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	serveMediaHubLots(w, r, userID, mediahub.ScopeAll)
}

type moderationRequest struct {
	RequestIDs []int           `json:"requestIds"`
	Action     mediahub.Action `json:"action"`
	Reason     string          `json:"reason"`
}

// maxModeratedIDs : un lot est une série, une ligne par saison.
const maxModeratedIDs = 60

// MediaHubModerateRequests approuve, refuse ou supprime les lignes d'un lot
// (POST /api/requests/moderation), au nom du compte.
func MediaHubModerateRequests(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var req moderationRequest
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !req.Action.Valid() ||
		len(req.RequestIDs) == 0 || len(req.RequestIDs) > maxModeratedIDs || len(req.Reason) > 500 {
		writeMediaHubError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	for _, id := range req.RequestIDs {
		if id <= 0 {
			writeMediaHubError(w, http.StatusBadRequest, "Invalid request body")
			return
		}
	}
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	if err := mediaHubClient(mediaHubHTTPClient).Moderate(r.Context(), account, req.RequestIDs, req.Action, req.Reason); err != nil {
		writeMediaHubFailure(w, "MediaHubModerateRequests", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(statusResponse{Status: "ok"})
}
