package indexer

import (
	"path/filepath"
	"testing"
	"time"
)

func TestAnnouncedImportScansItsFolderWhenItIsInALibrary(t *testing.T) {
	root := t.TempDir()
	m := testMonitor(t, root)
	monitorMu.Lock()
	previous := monitor
	monitor = m
	monitorMu.Unlock()
	t.Cleanup(func() {
		monitorMu.Lock()
		monitor = previous
		monitorMu.Unlock()
	})
	// Le poll anticipé vient d'avoir lieu : ce test ne regarde que le dossier visé.
	lastNudgePoll.Store(time.Now().UnixNano())

	episode := filepath.Join(root, "Severance", "Season 02", "Severance.S02E01.mkv")
	NudgeLibraryMonitor(episode, filepath.Join(t.TempDir(), "ailleurs", "film.mkv"), "")

	m.mu.Lock()
	defer m.mu.Unlock()
	target, ok := m.targets[filepath.Dir(episode)]
	if !ok || !target.deep {
		t.Fatalf("dossier de l'épisode non programmé en profondeur : %+v", m.targets)
	}
	// Un chemin hors des bibliothèques (montages différents) n'est pas parcouru.
	if len(m.targets) != 1 {
		t.Fatalf("cibles = %v, attendu le seul dossier de l'épisode", m.targets)
	}
	if delay := time.Until(target.due); delay < nudgeDelay-time.Second {
		t.Fatalf("parcours prévu dans %v, attendu ~%v pour laisser l'import finir", delay, nudgeDelay)
	}
}

func TestNudgeWithoutMonitorDoesNothing(t *testing.T) {
	monitorMu.Lock()
	previous := monitor
	monitor = nil
	monitorMu.Unlock()
	t.Cleanup(func() {
		monitorMu.Lock()
		monitor = previous
		monitorMu.Unlock()
	})
	NudgeLibraryMonitor("/films/Matrix (1999)/Matrix.mkv")
}
