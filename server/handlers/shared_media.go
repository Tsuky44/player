package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
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
// journaux d'un proxy — l'app web le lit dans le fragment (/share#code), que
// le navigateur n'envoie jamais au serveur.

// shareLinkLimiter compte les mauvais mots de passe par lien, toutes adresses
// confondues, comme accountLoginLimiter le fait par compte.
var shareLinkLimiter = newRateLimiter(20, 30*time.Second)

type sharedMediaRequest struct {
	Code     string `json:"code"`
	Password string `json:"password"`
	Viewer   string `json:"viewer"`
	Ticket   string `json:"ticket"`
	// MediaID désigne l'épisode voulu dans le lien d'une saison ou d'une
	// série ; absent pour un film ou un épisode, que le lien désigne seul.
	MediaID int `json:"media_id"`
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
		info = describeSharedMedia(share, share.MediaID)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(info)
}

// sharePasswordExhausted répond 429 quand trop de mauvais mots de passe ont
// été essayés sur ce lien.
func sharePasswordExhausted(w http.ResponseWriter, code string) bool {
	if !shareLinkLimiter.exhausted(code) {
		return false
	}
	w.Header().Set("Retry-After", "30")
	writeJSONError(w, http.StatusTooManyRequests, "Trop de tentatives sur ce lien, réessaie dans un moment.")
	return true
}

// SharedMediaContents décrit un lien une fois son mot de passe donné
// (POST /api/shared/contents) : pour une saison ou une série, la liste des
// épisodes à choisir. Rien n'est réservé ni délivré : le ticket vient de
// /open, épisode par épisode. Le mot de passe y est vérifié comme à
// l'ouverture, avec les mêmes limites.
func SharedMediaContents(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok || sharePasswordExhausted(w, req.Code) {
		return
	}
	share, err := shareLinks().Unlock(req.Code, req.Password)
	if err != nil {
		if errors.Is(err, sharelinks.ErrPassword) {
			shareLinkLimiter.allow(req.Code)
		}
		writeShareError(w, "SharedMediaContents", err)
		return
	}
	if share.SingleUse && share.Claimed {
		if _, err := shareLinks().Authorize(req.Code, req.Viewer); err != nil {
			writeShareError(w, "SharedMediaContents", err)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(describeSharedMedia(share, share.MediaID))
}

// OpenSharedMedia ouvre un lien (POST /api/shared/open) : vérifie le mot de
// passe, réserve un lien à usage unique à ce navigateur, et délivre un ticket
// de lecture au nom du lien. Le lien d'une saison ou d'une série dit quel
// épisode il veut (media_id) ; le ticket n'ouvre que celui-là.
func OpenSharedMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok || sharePasswordExhausted(w, req.Code) {
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
	mediaID, ok := sharedPlayTarget(share, req.MediaID)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "Ce média n'est pas, ou plus, disponible sur ce lien.")
		return
	}

	token, ticket, err := PlaybackTickets.IssueShare(share.ID, mediaID)
	if err != nil {
		log.Printf("OpenSharedMedia: ticket for share %d: %v", share.ID, err)
		w.Header().Set("Retry-After", "30")
		writeJSONError(w, http.StatusServiceUnavailable, "Trop de lectures en cours sur ce lien, réessaie dans un moment.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.SharedMediaAccess{
		Media:             describeSharedMedia(share, mediaID),
		MediaID:           mediaID,
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
	mediaID, live := sharedTicketMedia(share, req)
	if !live {
		writeJSONError(w, http.StatusUnauthorized, "La lecture a expiré, recharge la page.")
		return
	}

	consumed := !share.ConsumedAt.IsZero()
	if share.SingleUse && !consumed &&
		reachedWatchedThreshold(req.PositionSeconds, sharedMediaDuration(mediaID, req.DurationSeconds)) {
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

// SharedMediaTracks liste les pistes audio et de sous-titres du média d'un
// lien (POST /api/shared/tracks), pour que le lecteur de l'app les propose au
// visiteur comme à un compte. Il faut un ticket vivant de ce lien : c'est lui
// qui prouve que le mot de passe a été donné.
func SharedMediaTracks(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok {
		return
	}
	share, err := shareLinks().Authorize(req.Code, req.Viewer)
	if err != nil {
		writeShareError(w, "SharedMediaTracks", err)
		return
	}
	mediaID, live := sharedTicketMedia(share, req)
	if !live {
		writeJSONError(w, http.StatusUnauthorized, "La lecture a expiré, recharge la page.")
		return
	}
	GetMediaTracks(w, r, httprouter.Params{{Key: "id", Value: strconv.Itoa(mediaID)}}, 0)
}

// sharedTicketMedia renvoie le média que lit le ticket de la requête, s'il est
// vivant et s'il est bien un ticket de ce lien. Pour une saison ou une série,
// la page nomme l'épisode (media_id) ; le ticket, délivré par /open pour un
// épisode du lien, est la preuve qu'il en fait partie.
func sharedTicketMedia(share sharelinks.Share, req sharedMediaRequest) (int, bool) {
	mediaID := share.MediaID
	if req.MediaID > 0 {
		mediaID = req.MediaID
	}
	ticket, live := PlaybackTickets.Validate(req.Ticket, mediaID)
	return mediaID, live && ticket.ShareID == share.ID
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

// describeSharedMedia nomme pour le visiteur le média mediaID d'un lien :
// celui du lien lui-même — avec ses épisodes pour une saison ou une série —
// ou l'épisode qu'il vient d'y ouvrir.
func describeSharedMedia(share sharelinks.Share, mediaID int) models.SharedMedia {
	info := models.SharedMedia{
		NeedsPassword: share.HasPassword,
		SingleUse:     share.SingleUse,
		ExpiresAt:     optionalTime(share.ExpiresAt),
		Duration:      sharedMediaDuration(mediaID, 0),
	}
	display, err := loadShareDisplay(mediaID)
	if err != nil {
		log.Printf("describeSharedMedia: media %d: %v", mediaID, err)
		return info
	}
	info.MediaType = display.mediaType
	info.Title, info.Subtitle = display.title, display.subtitle
	info.PosterURL = display.posterURL
	if isShareCollection(display.mediaType) {
		if info.Episodes, err = loadSharedEpisodes(mediaID); err != nil {
			log.Printf("describeSharedMedia: %v", err)
		}
	}
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
