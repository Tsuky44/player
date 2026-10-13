package database

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// seedLibrariesFromLegacyDirs reprend, une fois, les deux dossiers que le
// serveur connaissait avant les bibliothèques (ADR-0058) : le réglage
// movies_dir / series_dir, sinon MOVIES_DIR / SERIES_DIR, sinon le dossier par
// défaut de l'image. Une installation existante retrouve ainsi son catalogue
// sous deux bibliothèques qu'elle peut renommer.
//
// Un serveur neuf, lui, démarre sans bibliothèque : c'est son administrateur
// qui les déclare et les nomme, depuis l'app. L'image pose MOVIES_DIR et
// SERIES_DIR pour tout le monde ; ces deux variables et le dossier par défaut
// ne sont donc repris que si le catalogue contient déjà des fichiers. Un
// dossier enregistré dans les réglages est un choix : il est toujours repris.
func seedLibrariesFromLegacyDirs(tx *sql.Tx) error {
	var indexed bool
	if err := tx.QueryRow(`SELECT EXISTS(
		SELECT 1 FROM medias WHERE file_path IS NOT NULL AND file_path != '')`).Scan(&indexed); err != nil {
		return fmt.Errorf("seed libraries: %w", err)
	}
	legacy := []struct {
		setting, env, fallback, name, kind string
	}{
		{"movies_dir", "MOVIES_DIR", "/media/Films", "Films", "movies"},
		{"series_dir", "SERIES_DIR", "/media/Series", "Séries", "shows"},
	}
	for _, dir := range legacy {
		path, err := legacyDir(tx, dir.setting, dir.env, dir.fallback, indexed)
		if err != nil {
			return err
		}
		if path == "" {
			continue
		}
		// OR IGNORE : les deux anciens réglages pouvaient désigner le même
		// dossier, et un dossier ne porte qu'une bibliothèque.
		if _, err := tx.Exec(`INSERT OR IGNORE INTO libraries (name, kind, path) VALUES (?, ?, ?)`,
			dir.name, dir.kind, filepath.Clean(path)); err != nil {
			return fmt.Errorf("seed library %s: %w", dir.name, err)
		}
	}
	_, err := tx.Exec(`DELETE FROM app_settings WHERE key IN ('movies_dir', 'series_dir')`)
	return err
}

func legacyDir(tx *sql.Tx, setting, env, fallback string, indexed bool) (string, error) {
	var stored string
	err := tx.QueryRow(`SELECT value FROM app_settings WHERE key = ?`, setting).Scan(&stored)
	if err != nil && err != sql.ErrNoRows {
		return "", fmt.Errorf("read legacy setting %s: %w", setting, err)
	}
	if stored = strings.TrimSpace(stored); stored != "" {
		return stored, nil
	}
	if !indexed {
		return "", nil
	}
	if fromEnv := strings.TrimSpace(os.Getenv(env)); fromEnv != "" {
		return fromEnv, nil
	}
	if info, err := os.Stat(fallback); err == nil && info.IsDir() {
		return fallback, nil
	}
	return "", nil
}
