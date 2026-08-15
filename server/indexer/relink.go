package indexer

import (
	"log"
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
)

// RelinkEpisodesToShows re-attaches every episode to the show and season its
// path says it belongs to.
//
// A scan only looks at files it has never seen, so episodes indexed before the
// folder rules were fixed keep hanging under whatever show they were filed
// under — typically a category folder ("Animes") holding every series at once.
// Re-linking repairs that in place: rows keep their id, so watch progress and
// subtitles are preserved.
func RelinkEpisodesToShows(seriesRoot string) int {
	seriesRoot = strings.TrimSpace(seriesRoot)
	if seriesRoot == "" || database.DB == nil {
		return 0
	}

	type episodeRow struct {
		id       int
		path     string
		parentID int
		season   int
		episode  int
	}

	rows, err := database.DB.Query(`
		SELECT id, COALESCE(file_path, ''), COALESCE(parent_id, 0),
		       COALESCE(season_number, 0), COALESCE(episode_number, 0)
		FROM medias
		WHERE type = 'episode' AND file_path IS NOT NULL AND file_path != ''`)
	if err != nil {
		log.Printf("Indexer relink: query failed: %v", err)
		return 0
	}
	var episodes []episodeRow
	for rows.Next() {
		var ep episodeRow
		if err := rows.Scan(&ep.id, &ep.path, &ep.parentID, &ep.season, &ep.episode); err != nil {
			continue
		}
		episodes = append(episodes, ep)
	}
	rows.Close()

	showIDByTitle := map[string]int{}
	seasonIDByKey := map[string]int{}
	moved := 0

	for _, ep := range episodes {
		rel, err := filepath.Rel(seriesRoot, filepath.FromSlash(ep.path))
		if err != nil || strings.HasPrefix(rel, "..") {
			continue // outside this library root — leave it alone
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		fileName := filepath.Base(ep.path)

		seasonNum, episodeNum, ok := ResolveEpisodeNumbers(parts, fileName)
		if !ok {
			continue
		}
		showTitle := resolveShowTitleFromPath(parts, fileName)
		if showTitle == "" || showTitle == "Unknown Show" {
			continue
		}

		titleKey := strings.ToLower(showTitle)
		showID, cached := showIDByTitle[titleKey]
		if !cached {
			showID, err = findOrCreateShow(
				showTitle,
				resolveShowTMDBSearchKeyFromPath(parts, fileName),
				resolveShowFolderPath(seriesRoot, parts),
			)
			if err != nil {
				log.Printf("Indexer relink: cannot resolve show %q: %v", showTitle, err)
				continue
			}
			showIDByTitle[titleKey] = showID
		}

		seasonKey := titleKey + "|" + strconv.Itoa(seasonNum)
		seasonID, cached := seasonIDByKey[seasonKey]
		if !cached {
			seasonID, err = findOrCreateSeason(showID, seasonNum)
			if err != nil {
				continue
			}
			seasonIDByKey[seasonKey] = seasonID
		}

		if ep.parentID == seasonID && ep.season == seasonNum && ep.episode == episodeNum {
			continue
		}
		if _, err := database.DB.Exec(
			`UPDATE medias SET parent_id = ?, season_number = ?, episode_number = ? WHERE id = ?`,
			seasonID, seasonNum, episodeNum, ep.id,
		); err != nil {
			log.Printf("Indexer relink: failed to move episode %d: %v", ep.id, err)
			continue
		}
		if ep.parentID != seasonID {
			moved++
			log.Printf("Indexer relink: episode %d moved to %q S%02dE%02d", ep.id, showTitle, seasonNum, episodeNum)
		}
	}

	if moved > 0 {
		cleanEmptySeasonsAndShows()
		log.Printf("Indexer relink: %d episode(s) re-attached to the right show", moved)
	}
	return moved
}
