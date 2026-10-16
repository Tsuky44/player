package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/models"
	"project-player/server/safego"
	"project-player/server/sharelinks"
)

// L'avancement des spectateurs d'un lien, rangé sous le prénom que chacun
// donne en ouvrant le lien (ADR-0066). Il remplace la position gardée dans le
// navigateur : la même personne reprend où elle en était depuis un autre
// appareil, et deux personnes qui regardent la même saison ne se mélangent
// pas.

// shareProgressReaperInterval espace le ménage de l'avancement des liens
// expirés. Une heure suffit : un lien expiré ne s'ouvre déjà plus, ces lignes
// ne font qu'occuper la base.
const shareProgressReaperInterval = time.Hour

// StartShareProgressReaper supprime en arrière-plan l'avancement des liens
// expirés ou vus. Un lien supprimé emporte le sien tout de suite, par clé
// étrangère. À appeler une fois au démarrage, après InitDB.
func StartShareProgressReaper() {
	go safego.Forever("share progress reaper", func() {
		for {
			purgeEndedShareProgress()
			time.Sleep(shareProgressReaperInterval)
		}
	})
}

func purgeEndedShareProgress() {
	n, err := shareLinks().PurgeEndedProgress()
	if err != nil {
		log.Printf("Share progress reaper: %v", err)
		return
	}
	if n > 0 {
		log.Printf("Share progress reaper: removed %d row(s) of ended share links", n)
	}
}

// SharedMediaResume dit où en est le spectateur qui a donné ce prénom
// (POST /api/shared/resume). Le mot de passe y est vérifié comme à
// l'ouverture, avec les mêmes limites : l'avancement dit ce que le lien
// contient.
func SharedMediaResume(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	req, ok := decodeSharedMediaRequest(w, r)
	if !ok || sharePasswordExhausted(w, req.Code) {
		return
	}
	store := shareLinks()
	share, err := store.Unlock(req.Code, req.Password)
	if err != nil {
		if errors.Is(err, sharelinks.ErrPassword) {
			shareLinkLimiter.allow(req.Code)
		}
		writeShareError(w, "SharedMediaResume", err)
		return
	}
	if share.SingleUse && share.Claimed {
		if _, err := store.Authorize(req.Code, req.Viewer); err != nil {
			writeShareError(w, "SharedMediaResume", err)
			return
		}
	}
	progress, err := store.Progress(share.ID, req.Name)
	if errors.Is(err, sharelinks.ErrViewerName) {
		writeJSONError(w, http.StatusBadRequest, "Indiquez un prénom de 40 caractères au plus.")
		return
	}
	if err != nil {
		writeShareError(w, "SharedMediaResume", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.SharedViewerProgress{
		Name:        progress.Name,
		Positions:   progress.Positions,
		Finished:    progress.Finished,
		LastMediaID: progress.LastMediaID,
	})
}

// recordSharedViewerProgress note la position d'une lecture sous le prénom du
// spectateur. Sans prénom (une page d'avant l'ADR-0066), rien n'est gardé.
// Un échec ne fait pas échouer la requête : elle sert aussi à détruire un lien
// à usage unique, qui ne doit pas en dépendre.
func recordSharedViewerProgress(share sharelinks.Share, name string, mediaID, positionSeconds int, finished bool) {
	if name == "" {
		return
	}
	err := shareLinks().SaveProgress(share.ID, name, mediaID, positionSeconds, finished)
	switch {
	case err == nil, errors.Is(err, sharelinks.ErrViewerName):
		// Un prénom refusé l'a déjà été par /resume, qui l'a dit à la page.
	case errors.Is(err, sharelinks.ErrTooManyViewers):
		log.Printf("ReportSharedMediaProgress: share %d has %d viewers, progress of a new one not kept",
			share.ID, sharelinks.MaxViewersPerShare)
	default:
		log.Printf("ReportSharedMediaProgress: %v", err)
	}
}

// sharedViewerPosition est la position où le spectateur name s'était arrêté
// dans mediaID, ou 0.
func sharedViewerPosition(share sharelinks.Share, name string, mediaID int) int {
	if name == "" {
		return 0
	}
	progress, err := shareLinks().Progress(share.ID, name)
	if err != nil {
		if !errors.Is(err, sharelinks.ErrViewerName) {
			log.Printf("OpenSharedMedia: %v", err)
		}
		return 0
	}
	return progress.Positions[mediaID]
}
