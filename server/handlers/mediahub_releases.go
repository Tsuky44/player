package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"project-player/server/mediahub"

	"github.com/julienschmidt/httprouter"
)

// La recherche interactive des demandes (ADR-0098) : l'app liste les releases
// des indexeurs pour une saison ou un épisode, et en envoie une à Radarr/Sonarr.
// MediaHub juge le droit interactive_search d'après le rôle du compte de même
// nom ; Onyx exige en plus manage_settings (main.go), comme pour la modération :
// choisir une release télécharge quelque chose, et un nom pris à l'inscription
// ne doit pas suffire.

// releasesResponse est la liste que lit l'app (contract/request_releases.json).
type releasesResponse = mediahub.ReleaseList

// maxGrabBody borne le corps d'un choix : une release tient en quelques Ko.
const maxGrabBody = 16 << 10

// MediaHubReleases rend les releases d'un film, d'une saison ou d'un épisode
// (GET /api/requests/releases?tmdbId=&type=&season=&episode=).
func MediaHubReleases(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	target, ok := releaseTargetFromQuery(r)
	if !ok {
		writeMediaHubError(w, http.StatusBadRequest, "Titre invalide")
		return
	}
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	list, err := mediaHubClient(mediaHubHTTPClient).Releases(r.Context(), account, target)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubReleases", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(list)
}

// MediaHubGrabRelease envoie la release choisie à Radarr ou Sonarr
// (POST /api/requests/releases/grab).
func MediaHubGrabRelease(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var grab mediahub.GrabRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxGrabBody)
	if err := json.NewDecoder(r.Body).Decode(&grab); err != nil || !grab.Valid() {
		writeMediaHubError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	if err := mediaHubClient(mediaHubHTTPClient).Grab(r.Context(), account, grab); err != nil {
		writeMediaHubFailure(w, "MediaHubGrabRelease", err)
		return
	}
	// Le téléchargement change l'état du titre : le statut gardé en cache
	// masquerait la saison qui arrive.
	invalidateMediaHubStatus(grab.TMDBID)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(statusResponse{Status: "ok"})
}

func releaseTargetFromQuery(r *http.Request) (mediahub.ReleaseTarget, bool) {
	query := r.URL.Query()
	tmdbID, err := strconv.Atoi(query.Get("tmdbId"))
	if err != nil {
		return mediahub.ReleaseTarget{}, false
	}
	target := mediahub.ReleaseTarget{TMDBID: tmdbID, MediaType: query.Get("type")}
	for name, field := range map[string]**int{"season": &target.Season, "episode": &target.Episode} {
		raw := query.Get(name)
		if raw == "" {
			continue
		}
		value, err := strconv.Atoi(raw)
		if err != nil {
			return mediahub.ReleaseTarget{}, false
		}
		*field = &value
	}
	return target, target.Valid()
}
