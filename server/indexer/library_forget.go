package indexer

import (
	"fmt"
	"log"
	"strings"

	"project-player/server/database"
	"project-player/server/libraries"
	"project-player/server/models"
	"project-player/server/streamcache"
)

// ForgetMediaUnder removes from the catalog the files indexed beneath dir,
// for a library that was deleted or pointed at another folder. It returns how
// many rows went.
//
// Rien d'autre ne le ferait : le nettoyage d'un scan ne retire que les fichiers
// qui ont disparu du disque, et ceux-là y sont toujours — ils resteraient au
// catalogue, lisibles, sans appartenir à aucune bibliothèque.
//
// Un fichier que l'une des bibliothèques restantes contient encore est gardé :
// deux bibliothèques peuvent être emboîtées, et retirer la plus large ne
// retire pas l'autre.
func ForgetMediaUnder(dir string, remaining []libraries.Library) (int, error) {
	if strings.TrimSpace(dir) == "" {
		return 0, nil
	}
	scanRun.Lock()
	defer scanRun.Unlock()

	lower, upper := pathPrefixRange(dir)
	rows, err := database.DB.Query(`SELECT id, file_path, type FROM medias
		WHERE file_path >= ? AND file_path < ?`, lower, upper)
	if err != nil {
		return 0, fmt.Errorf("forget medias under %s: %w", dir, err)
	}
	type item struct {
		id        int
		path      string
		mediaType string
	}
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.path, &it.mediaType); err != nil {
			rows.Close()
			return 0, fmt.Errorf("forget medias under %s: %w", dir, err)
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("forget medias under %s: %w", dir, err)
	}

	kept := func(path string) bool {
		for _, lib := range remaining {
			keepLower, keepUpper := pathPrefixRange(lib.Path)
			if path >= keepLower && path < keepUpper {
				return true
			}
		}
		return false
	}

	removed, removedEpisode := 0, false
	for _, it := range items {
		if kept(it.path) {
			continue
		}
		if _, err := database.DB.Exec(`DELETE FROM medias WHERE id = ?`, it.id); err != nil {
			log.Printf("Indexer: cannot forget %s: %v", it.path, err)
			continue
		}
		streamcache.Global().Invalidate(it.id)
		removed++
		if it.mediaType == string(models.TypeEpisode) {
			removedEpisode = true
		}
	}
	if removedEpisode {
		cleanEmptySeasonsAndShows()
	}
	if removed > 0 {
		log.Printf("Indexer: forgot %d media(s) under %s", removed, dir)
	}
	return removed, nil
}
