package indexer

import (
	"path/filepath"
	"regexp"
	"strings"

	"project-player/server/database"
)

var episodeFolderPrefixRe = regexp.MustCompile(`(?i)^s\d{1,2}e\d{1,3}`)

// ShowLocalLibraryHint returns the series folder name and a sample episode filename
// from indexed episode paths (for rematch UI and forced redetect).
func ShowLocalLibraryHint(showID int) (folder string, episodeFile string) {
	path := sampleShowEpisodePath(showID)
	if strings.TrimSpace(path) == "" {
		return "", ""
	}
	episodeFile = filepath.Base(path)
	folder = localShowFolderFromPath(path)
	return folder, episodeFile
}

func sampleShowEpisodePath(showID int) string {
	var filePath string
	err := database.DB.QueryRow(`
		SELECT COALESCE(ep.file_path, '')
		FROM medias ep
		WHERE ep.type = 'episode'
		  AND ep.file_path IS NOT NULL AND ep.file_path != ''
		  AND (
		    ep.parent_id IN (
		      SELECT id FROM medias WHERE type = 'season' AND parent_id = ?
		    )
		    OR ep.parent_id = ?
		  )
		ORDER BY ep.id ASC
		LIMIT 1`, showID, showID).Scan(&filePath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(filePath)
}

func localShowFolderFromPath(filePath string) string {
	filePath = filepath.ToSlash(strings.TrimSpace(filePath))
	if filePath == "" {
		return ""
	}
	parts := strings.Split(filePath, "/")
	if len(parts) == 0 {
		return ""
	}
	for i := len(parts) - 2; i >= 0; i-- {
		part := strings.TrimSpace(parts[i])
		if part == "" {
			continue
		}
		lower := strings.ToLower(part)
		if strings.HasPrefix(lower, "season ") || strings.HasPrefix(lower, "saison ") {
			continue
		}
		if episodeFolderPrefixRe.MatchString(part) {
			continue
		}
		if looksLikeEpisodeReleaseFolder(part) {
			continue
		}
		return part
	}
	return filepath.Base(filePath)
}

// RefreshAllSeasonsEpisodesFromTMDB refreshes episode metadata for every season of a show.
func RefreshAllSeasonsEpisodesFromTMDB(showID int) {
	rows, err := database.DB.Query(
		`SELECT id FROM medias WHERE type = 'season' AND parent_id = ?`, showID,
	)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var seasonID int
		if err := rows.Scan(&seasonID); err != nil {
			continue
		}
		RefreshSeasonEpisodesFromTMDB(seasonID)
	}
}
