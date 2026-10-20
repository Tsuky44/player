package handlers

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"

	"project-player/server/config"
	"project-player/server/indexer"

	"github.com/julienschmidt/httprouter"
)

// Un import que Radarr ou Sonarr vient de faire, annoncé par OnyxHub
// (ADR-0074) : la disponibilité de ce titre change, et le fichier est à
// indexer maintenant plutôt qu'au prochain passage du moniteur.

type onyxHubImportRequest struct {
	TMDBID    int      `json:"tmdbId"`
	MediaType string   `json:"mediaType"`
	Paths     []string `json:"paths"`
}

// maxImportPaths : une saison entière tient largement dedans.
const maxImportPaths = 100

// onyxHubKeyMatches compare en temps constant la clé présentée à celle
// qu'Onyx présente lui-même à OnyxHub : c'est le même secret partagé.
func onyxHubKeyMatches(r *http.Request) bool {
	expected := strings.TrimSpace(config.MediaHubAPIKey())
	presented := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	return expected != "" && presented != "" && subtle.ConstantTimeCompare([]byte(expected), []byte(presented)) == 1
}

// OnyxHubImported reçoit l'annonce (POST /api/integrations/onyxhub/imported).
// Sans compte : c'est OnyxHub qui appelle, avec la clé d'intégration.
func OnyxHubImported(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	if !onyxHubKeyMatches(r) {
		writeJSONError(w, http.StatusUnauthorized, "Clé d'intégration invalide")
		return
	}
	var req onyxHubImportRequest
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Paths) > maxImportPaths {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	invalidateMediaHubStatus(req.TMDBID)
	indexer.NudgeLibraryMonitor(req.Paths...)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(statusResponse{Status: "queued"})
}
