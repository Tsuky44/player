package streaming

import (
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// L'espace de travail des sessions HLS : où elles écrivent, combien peuvent
// tourner, et ce qu'il faut de disque pour en ouvrir une de plus.

// hlsWorkspace est le dossier où chaque session crée le sien.
//
// Les sessions écrivaient directement dans le dossier temporaire du système,
// mêlées à tout le reste. Un serveur tué sans avoir fermé ses sessions y
// laissait donc leurs segments — des gigaoctets pour une recopie de remux — que
// personne ne pouvait plus reconnaître comme les siens. Dans un dossier à
// elles, ce qui reste au démarrage est forcément orphelin (resetWorkspace).
// HLS_DIR le déplace, par exemple sur un disque plus grand ou en mémoire.
func hlsWorkspace() string {
	if dir := strings.TrimSpace(os.Getenv("HLS_DIR")); dir != "" {
		return dir
	}
	return filepath.Join(os.TempDir(), "onyx-hls")
}

// resetWorkspace crée le dossier et efface les sessions qu'un processus
// précédent y a laissées. Seuls les dossiers nommés comme une session sont
// touchés : HLS_DIR peut désigner un dossier partagé, et rien d'autre n'y est
// à nous.
func resetWorkspace(root string) {
	if err := os.MkdirAll(root, 0o755); err != nil {
		log.Printf("HLS: workspace %s unavailable: %v", root, err)
		return
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		log.Printf("HLS: cannot list workspace %s: %v", root, err)
		return
	}
	removed := 0
	for _, entry := range entries {
		if !entry.IsDir() || !strings.HasPrefix(entry.Name(), "hls-") {
			continue
		}
		if err := os.RemoveAll(filepath.Join(root, entry.Name())); err != nil {
			log.Printf("HLS: cannot remove orphan session %s: %v", entry.Name(), err)
			continue
		}
		removed++
	}
	if removed > 0 {
		log.Printf("HLS: removed %d session folder(s) left by a previous run", removed)
	}
}

// maxTranscodes est le nombre de sessions qui peuvent tourner en même temps.
//
// Rien ne les bornait : chaque /start lançait un FFmpeg de plus, et assez de
// lecteurs ouverts — ou un client qui en ouvre en boucle — mettaient la machine
// à genoux pour tout le monde. La moitié des cœurs, au moins quatre : une
// session d'encodage en occupe plusieurs à elle seule, une recopie presque
// rien. MAX_TRANSCODES le change ; 0 retire la limite.
func maxTranscodes() int {
	if raw := strings.TrimSpace(os.Getenv("MAX_TRANSCODES")); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n >= 0 {
			return n
		}
		log.Printf("HLS: invalid MAX_TRANSCODES %q, using the default", raw)
	}
	n := runtime.NumCPU() / 2
	if n < 4 {
		n = 4
	}
	return n
}

// minFreeBytes est l'espace qu'il doit rester libre sur l'espace de travail
// pour ouvrir une session. Une session qui remplit le disque ne casse pas
// qu'elle-même : la base, les journaux et le système partagent souvent ce
// disque. HLS_MIN_FREE_MB le change ; 0 retire la garde.
func minFreeBytes() uint64 {
	const defaultMB = 2048
	if raw := strings.TrimSpace(os.Getenv("HLS_MIN_FREE_MB")); raw != "" {
		if mb, err := strconv.ParseUint(raw, 10, 64); err == nil {
			return mb << 20
		}
		log.Printf("HLS: invalid HLS_MIN_FREE_MB %q, using the default", raw)
	}
	return defaultMB << 20
}

// retainSeconds est ce qu'une session garde derrière le dernier segment
// demandé, quand le client sait en rouvrir une pour reculer plus loin.
//
// Sans purge, une session garde tous ses segments jusqu'à sa fin : une recopie
// de remux à 30 Mbit/s écrit plus de 13 Go par heure dans l'espace de
// travail. HLS_RETAIN_MINUTES le change.
func retainSeconds() int {
	const defaultMinutes = 30
	if raw := strings.TrimSpace(os.Getenv("HLS_RETAIN_MINUTES")); raw != "" {
		if m, err := strconv.Atoi(raw); err == nil && m > 0 {
			return m * 60
		}
		log.Printf("HLS: invalid HLS_RETAIN_MINUTES %q, using the default", raw)
	}
	return defaultMinutes * 60
}
