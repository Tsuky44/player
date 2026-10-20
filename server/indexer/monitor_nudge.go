package indexer

import (
	"path/filepath"
	"sync/atomic"
	"time"

	"project-player/server/safego"
)

// Un import annoncé par OnyxHub (ADR-0074).
//
// Radarr et Sonarr préviennent OnyxHub dès qu'un fichier est rangé. Sans ce
// signal, le moniteur ne le voit que par une notification du système de
// fichiers — aveugle sur un partage réseau — ou au prochain passage du poll,
// cinq minutes plus tard par défaut. Le signal ne fait rien de plus que ce que
// le moniteur fait déjà : il avance le moment où il regarde.

// nudgeDelay laisse à Radarr/Sonarr le temps de finir : le webhook part quand
// l'import est décidé, le déplacement ou le lien dur peut suivre de peu.
const nudgeDelay = 15 * time.Second

// nudgePollGap : une saison importée d'un coup envoie un webhook par épisode ;
// un seul passage du poll les couvre tous.
const nudgePollGap = 30 * time.Second

var lastNudgePoll atomic.Int64

// NudgeLibraryMonitor fait regarder le moniteur sans attendre. path est le
// fichier ou le dossier annoncé, tel que Radarr/Sonarr le voient : quand il est
// dans une bibliothèque (mêmes montages), son dossier est parcouru en
// profondeur ; sinon, seul le poll anticipé le trouvera. Sans moniteur, rien
// ne se passe.
func NudgeLibraryMonitor(paths ...string) {
	m := activeMonitor()
	if m == nil {
		return
	}
	for _, path := range paths {
		if path == "" {
			continue
		}
		dir := filepath.Clean(path)
		if filepath.Ext(dir) != "" {
			dir = filepath.Dir(dir)
		}
		if _, _, ok := m.rootFor(dir); ok {
			m.enqueue(dir, true, nudgeDelay)
		}
	}

	now := time.Now().UnixNano()
	last := lastNudgePoll.Load()
	if now-last < int64(nudgePollGap) || !lastNudgePoll.CompareAndSwap(last, now) {
		return
	}
	go safego.Run("indexer/monitor_nudge.go:poll", func() {
		time.Sleep(nudgeDelay)
		m.pollOnce()
	})
}
