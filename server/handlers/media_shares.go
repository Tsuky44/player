package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/sharelinks"
)

// Liens de partage publics, côté créateur (ADR-0037). Les routes du visiteur
// sans compte sont dans shared_media.go.

func shareLinks() *sharelinks.Store { return sharelinks.New(database.DB) }

// CreateMediaShareRequest est le corps de POST /api/shares.
type CreateMediaShareRequest struct {
	MediaID  int    `json:"media_id"`
	Password string `json:"password"`
	// SingleUse : le lien est détruit quand le premier navigateur qui l'a
	// ouvert a vu le média.
	SingleUse bool `json:"single_use"`
	// ExpiresInHours vaut 0 (sans échéance), 24, 168 ou 720.
	ExpiresInHours int `json:"expires_in_hours"`
}

// CreateMediaShare crée un lien public vers un film ou un épisode
// (POST /api/shares). Le code n'est rendu que cette fois-ci.
func CreateMediaShare(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var req CreateMediaShareRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || req.MediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Requête invalide")
		return
	}
	if !isPlayableMedia(req.MediaID) {
		writeJSONError(w, http.StatusNotFound, "Ce média ne peut pas être lu")
		return
	}

	code, share, err := shareLinks().Create(sharelinks.CreateParams{
		UserID:        userID,
		MediaID:       req.MediaID,
		Password:      req.Password,
		SingleUse:     req.SingleUse,
		LifetimeHours: req.ExpiresInHours,
	})
	if errors.Is(err, sharelinks.ErrInvalid) {
		writeJSONError(w, http.StatusBadRequest, "Durée ou mot de passe invalide (72 caractères au plus)")
		return
	}
	if err != nil {
		log.Printf("CreateMediaShare: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	snap, err := loadMediaSnapshot(share.MediaID)
	if err != nil {
		log.Printf("CreateMediaShare: snapshot of media %d: %v", share.MediaID, err)
	}
	resp := mediaShareResponse(share, snap, time.Now())
	resp.Code = code
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(resp)
}

// ListMediaShares renvoie les liens créés par l'appelant (GET /api/shares),
// y compris ceux qui ont expiré ou ont été vus, pour qu'il sache ce qu'ils
// sont devenus.
func ListMediaShares(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	shares, err := shareLinks().ListByUser(userID)
	if err != nil {
		log.Printf("ListMediaShares: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	ids := make([]int, 0, len(shares))
	for _, share := range shares {
		ids = append(ids, share.MediaID)
	}
	snaps, err := loadMediaSnapshots(ids)
	if err != nil {
		log.Printf("ListMediaShares: snapshots: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	now := time.Now()
	out := make([]models.MediaShare, 0, len(shares))
	for _, share := range shares {
		out = append(out, mediaShareResponse(share, snaps[share.MediaID], now))
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// DeleteMediaShare supprime un lien de l'appelant (DELETE /api/shares/:id) et
// coupe aussitôt les lectures qu'il avait ouvertes.
func DeleteMediaShare(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || id <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Identifiant invalide")
		return
	}
	if err := shareLinks().Delete(id, userID); err != nil {
		if errors.Is(err, sharelinks.ErrNotFound) {
			writeJSONError(w, http.StatusNotFound, "Lien introuvable")
			return
		}
		log.Printf("DeleteMediaShare: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	PlaybackTickets.RevokeShare(id)
	w.WriteHeader(http.StatusNoContent)
}

// revokeMediaShares supprime tous les liens de userID, qui vient de perdre le
// droit d'en créer : comme les invitations, ceux qui circulent meurent avec lui.
func revokeMediaShares(userID int) error {
	ids, err := shareLinks().DeleteAllBy(userID)
	if err != nil {
		return err
	}
	for _, id := range ids {
		PlaybackTickets.RevokeShare(id)
	}
	return nil
}

// isPlayableMedia dit si mediaID est un film ou un épisode qui a un fichier :
// la même règle que pour délivrer un ticket de lecture.
func isPlayableMedia(mediaID int) bool {
	var found int
	err := database.DB.QueryRow(
		"SELECT id FROM medias WHERE id = ? AND type IN ('movie', 'episode') AND COALESCE(file_path, '') != ''",
		mediaID).Scan(&found)
	return err == nil
}

func mediaShareResponse(share sharelinks.Share, snap mediaSnapshot, now time.Time) models.MediaShare {
	title, subtitle := shareDisplayTitle(snap)
	return models.MediaShare{
		ID:          share.ID,
		MediaID:     share.MediaID,
		MediaType:   snap.mediaType,
		Title:       title,
		Subtitle:    subtitle,
		PosterURL:   snap.posterURL,
		HasPassword: share.HasPassword,
		SingleUse:   share.SingleUse,
		ExpiresAt:   optionalTime(share.ExpiresAt),
		Claimed:     share.Claimed,
		ConsumedAt:  optionalTime(share.ConsumedAt),
		Views:       share.Views,
		Status:      share.Status(now),
		CreatedAt:   share.CreatedAt,
	}
}

// shareDisplayTitle nomme un média pour quelqu'un qui ne voit que le lien :
// la série d'abord pour un épisode, le numéro et le titre de l'épisode ensuite.
func shareDisplayTitle(snap mediaSnapshot) (string, string) {
	if snap.mediaType != string(models.TypeEpisode) || snap.showTitle == "" {
		return snap.title, ""
	}
	parts := []string{}
	if snap.subtitle != "" {
		parts = append(parts, snap.subtitle)
	}
	if snap.title != "" {
		parts = append(parts, snap.title)
	}
	return snap.showTitle, strings.Join(parts, " · ")
}

func optionalTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}
