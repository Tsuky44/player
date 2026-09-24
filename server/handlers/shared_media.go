package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/sharelinks"
)

// Liens de partage publics, côté visiteur sans compte (ADR-0037).
//
// Toutes ces routes sont publiques : le code du lien est la seule clé. Il
// voyage dans le corps JSON, jamais dans l'URL, pour ne pas finir dans les
// journaux d'un proxy — la page le lit dans le fragment (#code), que le
// navigateur n'envoie jamais au serveur.

// shareLinkLimiter compte les mauvais mots de passe par lien, toutes adresses
// confondues, comme accountLoginLimiter le fait par compte.
var shareLinkLimiter = newRateLimiter(20, 30*time.Second)

type sharedMediaRequest struct {
	Code     string `json:"code"`
	Password string `json:"password"`
	Viewer   string `json:"viewer"`
	Ticket   string `json:"ticket"`
	// PositionSeconds et DurationSeconds ne servent qu'à /progress.
	PositionSeconds int `json:"position_seconds"`
	DurationSeconds int `json:"duration_seconds"`
}

func decodeSharedMediaRequest(w http.ResponseWriter, r *http.Request) (sharedMediaRequest, bool) {
	var req sharedMediaRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || req.Code == "" {
		writeJSONError(w, http.StatusBadRequest, "Lien invalide")
		return req, false
	}
	w.Header().Set("Cache-Control", "no-store")
	return req, true
}

// writeShareError traduit une erreur de sharelinks en réponse pour le
// visiteur. Les phrases s'affichent telles quelles sur la page du lien.
func writeShareError(w http.ResponseWriter, handler string, err error) {
	switch {
	case errors.Is(err, sharelinks.ErrNotFound):
		writeJSONError(w, http.StatusNotFound, "Ce lien n'existe pas ou a été supprimé.")
	case errors.Is(err, sharelinks.ErrGone):
		writeJSONError(w, http.StatusGone, "Ce lien a expiré ou a déjà été utilisé.")
	case errors.Is(err, sharelinks.ErrPassword):
		writeJSONError(w, http.StatusUnauthorized, "Mot de passe incorrect.")
	case errors.Is(err, sharelinks.ErrClaimed):
		writeJSONError(w, http.StatusConflict, "Ce lien est à usage unique et il est déjà ouvert sur un autre appareil.")
	default:
		log.Printf("%s: %v", handler, err)
		writeJSONError(w, http.StatusInternalServerError, "Le serveur n'a pas pu ouvrir ce lien.")
	}
}

// SharedMediaInfo décrit un lien avant son ouverture (POST /api/shared/info) :
// faut-il un mot de passe, et, sinon, quel média il ouvre.
func SharedMediaInfo(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	store := shareLinks()
	share, err := store.Find(req.Code)
	if err == nil && share.Status(time.Now()) != "active" {
		err = sharelinks.ErrGone
	}
	if err == nil && share.SingleUse && share.Claimed {
		// Un autre navigateur l'a réservé : autant le dire avant de faire
		// saisir un mot de passe pour rien.
		_, err = store.Authorize(req.Code, req.Viewer)
	}
	if err != nil {
		writeShareError(w, "SharedMediaInfo", err)
		return
	}

	info := models.SharedMedia{
		NeedsPassword: share.HasPassword,
		SingleUse:     share.SingleUse,
		ExpiresAt:     optionalTime(share.ExpiresAt),
	}
	if !share.HasPassword {
		info = describeSharedMedia(share)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(info)
}

// OpenSharedMedia ouvre un lien (POST /api/shared/open) : vérifie le mot de
// passe, réserve un lien à usage unique à ce navigateur, et délivre un ticket
// de lecture au nom du lien.
func OpenSharedMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	if shareLinkLimiter.exhausted(req.Code) {
		w.Header().Set("Retry-After", "30")
		writeJSONError(w, http.StatusTooManyRequests, "Trop de tentatives sur ce lien, réessaie dans un moment.")
		return
	}
	share, viewer, err := shareLinks().Open(req.Code, req.Password, req.Viewer)
	if err != nil {
		if errors.Is(err, sharelinks.ErrPassword) {
			shareLinkLimiter.allow(req.Code)
		}
		writeShareError(w, "OpenSharedMedia", err)
		return
	}

	token, ticket, err := PlaybackTickets.IssueShare(share.ID, share.MediaID)
	if err != nil {
		log.Printf("OpenSharedMedia: ticket for share %d: %v", share.ID, err)
		w.Header().Set("Retry-After", "30")
		writeJSONError(w, http.StatusServiceUnavailable, "Trop de lectures en cours sur ce lien, réessaie dans un moment.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.SharedMediaAccess{
		Media:             describeSharedMedia(share),
		MediaID:           share.MediaID,
		Ticket:            token,
		ExpiresAt:         ticket.ExpiresAt,
		RenewAfterSeconds: ticketRenewAfterSeconds,
		Viewer:            viewer,
	})
}

// RenewSharedMedia prolonge le ticket d'une lecture en cours
// (POST /api/shared/renew). Un lien supprimé, expiré ou vu depuis plus d'une
// heure ne renouvelle plus rien : la lecture s'arrête à l'échéance du ticket.
func RenewSharedMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	share, err := shareLinks().Authorize(req.Code, req.Viewer)
	if err != nil {
		writeShareError(w, "RenewSharedMedia", err)
		return
	}
	ticket, err := PlaybackTickets.RenewShare(req.Ticket, share.ID)
	if err != nil {
		writeJSONError(w, http.StatusUnauthorized, "La lecture a expiré, recharge la page.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.SharedMediaRenewal{ExpiresAt: ticket.ExpiresAt})
}

// ReportSharedMediaProgress reçoit la position d'une lecture
// (POST /api/shared/progress). C'est elle qui détruit un lien à usage unique :
// au seuil « vu », le même que pour la progression d'un compte.
//
// Rien n'est écrit dans la progression du créateur : le visiteur n'est pas lui.
func ReportSharedMediaProgress(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	store := shareLinks()
	share, err := store.Authorize(req.Code, req.Viewer)
	if err != nil {
		writeShareError(w, "ReportSharedMediaProgress", err)
		return
	}
	// Seul le navigateur qui lit peut détruire le lien, pas quiconque en
	// connaît le code.
	if ticket, live := PlaybackTickets.Validate(req.Ticket, share.MediaID); !live || ticket.ShareID != share.ID {
		writeJSONError(w, http.StatusUnauthorized, "La lecture a expiré, recharge la page.")
		return
	}

	consumed := !share.ConsumedAt.IsZero()
	if share.SingleUse && !consumed &&
		reachedWatchedThreshold(req.PositionSeconds, sharedMediaDuration(share.MediaID, req.DurationSeconds)) {
		if _, err := store.Consume(share.ID); err != nil {
			log.Printf("ReportSharedMediaProgress: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		consumed = true
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.SharedMediaProgress{Consumed: consumed})
}

// CloseSharedMedia révoque le ticket d'une page qui se ferme
// (POST /api/shared/close). Sans elle, le ticket vivrait jusqu'à son échéance.
func CloseSharedMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	if share, err := shareLinks().Find(req.Code); err == nil {
		PlaybackTickets.RevokeShareTicket(req.Ticket, share.ID)
	}
	w.WriteHeader(http.StatusNoContent)
}

// describeSharedMedia nomme le média d'un lien pour son visiteur.
func describeSharedMedia(share sharelinks.Share) models.SharedMedia {
	info := models.SharedMedia{
		NeedsPassword: share.HasPassword,
		SingleUse:     share.SingleUse,
		ExpiresAt:     optionalTime(share.ExpiresAt),
		Duration:      sharedMediaDuration(share.MediaID, 0),
	}
	snap, err := loadMediaSnapshot(share.MediaID)
	if err != nil {
		log.Printf("describeSharedMedia: media %d: %v", share.MediaID, err)
		return info
	}
	info.MediaType = snap.mediaType
	info.Title, info.Subtitle = shareDisplayTitle(snap)
	info.PosterURL = snap.posterURL
	return info
}

// sharedMediaDuration est la durée connue du média, ou celle que la page a
// mesurée quand l'indexation n'en a trouvé aucune. Une page qui ment ne peut
// que détruire plus tôt son propre lien.
func sharedMediaDuration(mediaID, measured int) int {
	var duration int
	if err := database.DB.QueryRow("SELECT COALESCE(duration, 0) FROM medias WHERE id = ?", mediaID).Scan(&duration); err != nil {
		log.Printf("sharedMediaDuration: media %d: %v", mediaID, err)
	}
	if duration <= 0 {
		return measured
	}
	return duration
}
