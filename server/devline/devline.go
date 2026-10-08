// Package devline bride le débit des flux vidéo pour reproduire, sur la
// machine de développement, une ligne qui ne suit pas.
//
// La qualité automatique du lecteur (ADR-0056) se décide sur ce que la ligne
// porte : sans ligne lente sous la main, rien ne permet de la voir descendre,
// ni remonter. Le bridage est commun à toutes les réponses — une ligne se
// partage entre le flux lu et la mesure que le lecteur fait à côté.
//
// Éteint tant que ONYX_DEV_LINE_KBPS n'est pas défini : Wrap rend alors le
// ResponseWriter tel quel et la route de réglage n'existe pas.
package devline

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/julienschmidt/httprouter"
)

const envKey = "ONYX_DEV_LINE_KBPS"

// chunk est ce qui part entre deux attentes. Assez petit pour qu'une ligne
// à 500 kbit/s avance par à-coups d'un dixième de seconde, pas d'une seconde.
const chunk = 8 * 1024

var shared = newLine()

type line struct {
	mu      sync.Mutex
	enabled bool
	bps     int64
	// next est l'instant où l'octet suivant a le droit de partir.
	next time.Time
}

func newLine() *line {
	l := &line{}
	raw, ok := os.LookupEnv(envKey)
	if !ok {
		return l
	}
	l.enabled = true
	kbps, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || kbps < 0 {
		log.Printf("devline: %s=%q illisible, ligne non bridée", envKey, raw)
		kbps = 0
	}
	l.bps = int64(kbps) * 1000
	log.Printf("devline: flux vidéo bridés à %d kbit/s (0 = libre) — développement seulement", kbps)
	return l
}

// Enabled dit si le bridage a été demandé au démarrage.
func Enabled() bool { return shared.enabled }

// reserve rend le temps à attendre avant d'envoyer n octets.
func (l *line) reserve(n int, now time.Time) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.bps <= 0 {
		return 0
	}
	if l.next.Before(now) {
		l.next = now
	}
	wait := l.next.Sub(now)
	l.next = l.next.Add(time.Duration(int64(n) * 8 * int64(time.Second) / l.bps))
	return wait
}

func (l *line) set(kbps int) {
	l.mu.Lock()
	l.bps = int64(kbps) * 1000
	l.next = time.Time{}
	l.mu.Unlock()
}

func (l *line) kbps() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return int(l.bps / 1000)
}

type writer struct {
	http.ResponseWriter
	line *line
}

func (w *writer) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		n := len(p)
		if n > chunk {
			n = chunk
		}
		if wait := w.line.reserve(n, time.Now()); wait > 0 {
			time.Sleep(wait)
		}
		m, err := w.ResponseWriter.Write(p[:n])
		written += m
		if err != nil {
			return written, err
		}
		p = p[n:]
	}
	return written, nil
}

func (w *writer) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *writer) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// Wrap rend un ResponseWriter dont les écritures respectent la ligne, ou w
// lui-même hors développement.
func Wrap(w http.ResponseWriter) http.ResponseWriter {
	if !shared.enabled {
		return w
	}
	return &writer{ResponseWriter: w, line: shared}
}

type lineResponse struct {
	Kbps int `json:"kbps"`
}

// Handle lit ou règle le débit de la ligne en cours de route
// (GET, PUT /api/dev/line?kbps=N), pour la voir se dégrader puis se rétablir
// pendant une lecture. À n'enregistrer que si Enabled.
func Handle(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	if r.Method == http.MethodPut {
		kbps, err := strconv.Atoi(r.URL.Query().Get("kbps"))
		if err != nil || kbps < 0 {
			http.Error(w, "kbps doit être un entier positif ou nul", http.StatusBadRequest)
			return
		}
		shared.set(kbps)
		log.Printf("devline: ligne réglée à %d kbit/s", kbps)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(lineResponse{Kbps: shared.kbps()})
}
