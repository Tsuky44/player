package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/julienschmidt/httprouter"
)

// MediaHubProgress rend le téléchargement et l'import d'un titre, lus chez
// MediaHub (GET /api/requests/progress?tmdbId=&type=). Le serveur ne garde
// rien : l'app interroge à chaque rafraîchissement, comme les widgets de
// MediaHub.
func MediaHubProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	tmdbID, err := strconv.Atoi(r.URL.Query().Get("tmdbId"))
	mediaType := r.URL.Query().Get("type")
	if err != nil || tmdbID <= 0 || (mediaType != "movie" && mediaType != "tv") {
		writeMediaHubError(w, http.StatusBadRequest, "Titre invalide")
		return
	}
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	progress, err := mediaHubClient(mediaHubHTTPClient).Progress(r.Context(), account, tmdbID, mediaType)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubProgress", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(progress)
}
