package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

var (
	// Durée maximale d'une attente. Sous le délai de réception de 30 s du
	// client Dio partagé, avec de la marge — la même que « Regarder ensemble ».
	progressRevisionPollWindow = 20 * time.Second

	// Relecture de secours pendant l'attente. Les routes du compte réveillent
	// les écrans elles-mêmes (NotifiesProgress) ; ce qui écrit en tâche de
	// fond — import d'un serveur lié, synchronisation Emby — ne le fait pas, et
	// arrive par ici.
	progressRevisionRecheck = 5 * time.Second
)

// progressWatchers réveille les écrans qui attendent un changement de
// progression. Un canal par compte, fermé au changement : tous les appareils
// en attente repartent d'un coup, sans liste d'abonnés à tenir.
type progressWatchers struct {
	mu      sync.Mutex
	changed map[int]chan struct{}

	// closing se ferme à l'arrêt du serveur : chaque attente répond alors
	// aussitôt, au lieu de tenir l'arrêt jusqu'à la fin de sa fenêtre.
	closing   chan struct{}
	closeOnce sync.Once
}

func newProgressWatchers() *progressWatchers {
	return &progressWatchers{
		changed: make(map[int]chan struct{}),
		closing: make(chan struct{}),
	}
}

// Shutdown rend la main à toutes les attentes, présentes et à venir.
func (p *progressWatchers) Shutdown() {
	p.closeOnce.Do(func() { close(p.closing) })
}

// ProgressWatchers est le registre du processus.
var ProgressWatchers = newProgressWatchers()

// wait rend le canal qui se fermera au prochain changement du compte.
func (p *progressWatchers) wait(userID int) <-chan struct{} {
	p.mu.Lock()
	defer p.mu.Unlock()
	ch, ok := p.changed[userID]
	if !ok {
		ch = make(chan struct{})
		p.changed[userID] = ch
	}
	return ch
}

// notify réveille tout ce qui attend sur ce compte.
func (p *progressWatchers) notify(userID int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if ch, ok := p.changed[userID]; ok {
		close(ch)
		delete(p.changed, userID)
	}
}

// NotifiesProgress enveloppe une route qui écrit la progression du compte :
// à son retour, les autres appareils qui attendent sur
// GET /api/progress/revision sont réveillés. Posé sur la route dans main.go
// plutôt que dans chaque handler, pour qu'aucun chemin de sortie ne l'oublie.
// Un réveil pour rien (requête refusée) ne coûte qu'une relecture du jeton.
func NotifiesProgress(next AuthenticatedHandle) AuthenticatedHandle {
	return func(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
		next(w, r, ps, userID)
		ProgressWatchers.notify(userID)
	}
}

// progressRevision rend un jeton qui change dès que ce que le compte a regardé
// change : une position qui avance sur un autre appareil, un épisode coché vu,
// une entrée retirée de « Reprendre la lecture ».
//
// Il ne coûte rien à tenir : progress_changes reçoit déjà un numéro neuf à
// chaque écriture de progression, par déclencheur, quel que soit le handler.
// Le nombre de lignes accompagne le plus grand numéro parce qu'une suppression
// (fusion de doublons) ne fait monter aucun numéro.
func progressRevision(userID int) (string, error) {
	var seq, changes, hidden int
	var hiddenAt string
	err := database.DB.QueryRow(`
		SELECT
			(SELECT COALESCE(MAX(seq), 0) FROM progress_changes WHERE user_id = ?),
			(SELECT COUNT(*) FROM progress_changes WHERE user_id = ?),
			(SELECT COUNT(*) FROM continue_watching_hidden WHERE user_id = ?),
			(SELECT COALESCE(MAX(CAST(hidden_at AS TEXT)), '') FROM continue_watching_hidden WHERE user_id = ?)
	`, userID, userID, userID, userID).Scan(&seq, &changes, &hidden, &hiddenAt)
	if err != nil {
		return "", fmt.Errorf("read progress revision: %w", err)
	}
	return fmt.Sprintf("%d.%d.%d.%s", seq, changes, hidden, hiddenAt), nil
}

// GetProgressRevision dit aux écrans ouverts quand relire leurs données
// (GET /api/progress/revision?since=…).
//
// Sans `since`, répond tout de suite. Avec, attend que le jeton s'en écarte,
// au plus [progressRevisionPollWindow] : l'accueil et les fiches apprennent
// ainsi un changement à l'instant où il arrive, pour une requête ouverte par
// écran visible au lieu d'un sondage toutes les quelques secondes.
func GetProgressRevision(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")
	since := r.URL.Query().Get("since")

	deadline := time.NewTimer(progressRevisionPollWindow)
	defer deadline.Stop()
	recheck := time.NewTicker(progressRevisionRecheck)
	defer recheck.Stop()

	for {
		// Le canal est pris avant la lecture : un changement qui tombe entre
		// les deux le ferme, et l'attente repart aussitôt au lieu de le rater.
		changed := ProgressWatchers.wait(userID)
		revision, err := progressRevision(userID)
		if err != nil {
			log.Printf("GetProgressRevision: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal database error")
			return
		}
		expired := false
		if since != "" && revision == since {
			select {
			case <-changed:
				continue
			case <-recheck.C:
				continue
			case <-deadline.C:
				expired = true
			case <-ProgressWatchers.closing:
				expired = true
			case <-r.Context().Done():
				return
			}
		}
		if since == "" || revision != since || expired {
			json.NewEncoder(w).Encode(models.ProgressRevision{Revision: revision})
			return
		}
	}
}
