// Package logging règle le journal du serveur.
//
// Le serveur écrit avec log.Printf depuis toujours, en texte libre et sans
// niveau. Setup installe log/slog comme journal par défaut : les appels
// existants passent par lui au niveau Info, sans qu'il faille les réécrire, et
// le nouveau code peut écrire des champs et des niveaux (slog.Debug,
// slog.Warn…). LOG_FORMAT=json donne une ligne JSON par entrée, pour un
// collecteur de journaux ; LOG_LEVEL règle ce qui est écrit.
package logging

import (
	"io"
	"log/slog"
	"os"
	"strings"
)

// Setup installe le journal par défaut, lu dans l'environnement.
func Setup() {
	slog.SetDefault(slog.New(newHandler(os.Stderr, os.Getenv("LOG_FORMAT"), os.Getenv("LOG_LEVEL"))))
}

func newHandler(w io.Writer, format, level string) slog.Handler {
	opts := &slog.HandlerOptions{Level: parseLevel(level)}
	if strings.EqualFold(strings.TrimSpace(format), "json") {
		return slog.NewJSONHandler(w, opts)
	}
	return slog.NewTextHandler(w, opts)
}

func parseLevel(raw string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
