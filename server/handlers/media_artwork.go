package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"project-player/server/artwork"
	"project-player/server/config"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// remotePostersTimeout borne l'attente des sites d'images : TMDB et
// Fanart.tv sont interrogés en même temps, et la feuille de choix attend.
const remotePostersTimeout = 15 * time.Second

// GetRemotePosters liste les affiches que TMDB et Fanart.tv proposent pour un
// film ou une série (GET /api/media/:id/images/posters). Voir ADR-0068.
func GetRemotePosters(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}
	target, err := artwork.Load(mediaID)
	if errors.Is(err, artwork.ErrNotFound) {
		writeJSONError(w, http.StatusNotFound, "Media not found")
		return
	}
	if err != nil {
		log.Printf("GetRemotePosters: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Unable to read media")
		return
	}

	resp := models.RemotePosters{
		Current:       target.Poster,
		Locked:        target.Locked,
		FanartEnabled: config.FanartAPIKey() != "",
		Images:        []models.RemoteImage{},
	}
	// Une fiche que TMDB n'a pas identifiée n'a pas d'affiches à proposer :
	// la liste vide dit à l'app d'inviter à corriger la fiche d'abord.
	if target.TMDBID > 0 {
		ctx, cancel := context.WithTimeout(r.Context(), remotePostersTimeout)
		defer cancel()
		if images := artwork.Posters(ctx, target.Type, target.TMDBID, languageOf(r).code); images != nil {
			resp.Images = images
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

type setPosterRequest struct {
	URL string `json:"url"`
}

// SetMediaPoster enregistre l'affiche choisie parmi celles de
// GetRemotePosters (PUT /api/media/:id/poster) et répond la fiche à jour.
func SetMediaPoster(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}
	var req setPosterRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	err = artwork.Choose(mediaID, req.URL)
	if !writeArtworkError(w, "SetMediaPoster", err) {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	writeMediaByID(w, r, mediaID)
}

// ResetMediaPoster rend la fiche à l'affiche par défaut de TMDB
// (DELETE /api/media/:id/poster) et répond la fiche à jour.
func ResetMediaPoster(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}
	if !writeArtworkError(w, "ResetMediaPoster", artwork.Reset(mediaID)) {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	writeMediaByID(w, r, mediaID)
}

// writeArtworkError répond l'erreur d'une écriture d'affiche, et dit si
// l'appelant peut continuer.
func writeArtworkError(w http.ResponseWriter, handler string, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, artwork.ErrNotFound):
		writeJSONError(w, http.StatusNotFound, "Media not found")
	case errors.Is(err, artwork.ErrHostNotAllowed):
		writeJSONError(w, http.StatusBadRequest, "Image host not allowed")
	default:
		log.Printf("%s: %v", handler, err)
		writeJSONError(w, http.StatusInternalServerError, "Unable to save poster")
	}
	return false
}
