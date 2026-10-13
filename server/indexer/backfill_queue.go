package indexer

import (
	"log"

	"project-player/server/database"
	"project-player/server/models"
)

// loadBackfillQueue lists the movies and shows whose card is incomplete, for
// the TMDB backfill. The videos of a plain library are left out: they have no
// card to complete (plain_libraries.go).
func loadBackfillQueue() []struct {
	id        int
	mediaType models.MediaType
	title     string
	filePath  string
	tmdbID    int
} {
	identifiable, args := OutsidePlainLibraries("file_path")
	rows, err := database.DB.Query(`
		SELECT id, type, title, COALESCE(file_path, ''), COALESCE(tmdb_id, 0)
		FROM medias
		WHERE type IN ('movie', 'show')`+identifiable+`
		  AND (
		    poster_url IS NULL OR poster_url = ''
		    OR overview IS NULL OR overview = ''
		    OR tmdb_id IS NULL OR tmdb_id = 0
		    OR title LIKE '%WEBDL%'
		    OR title LIKE '%webdl%'
		    OR title LIKE '%.mkv%'
		    OR title LIKE '%1080p%'
		    OR title LIKE '%720p%'
		  )
		ORDER BY type, title
	`, args...)
	if err != nil {
		log.Printf("TMDB: backfill query failed: %v", err)
		return nil
	}
	defer rows.Close()

	var items []struct {
		id        int
		mediaType models.MediaType
		title     string
		filePath  string
		tmdbID    int
	}
	for rows.Next() {
		var id, tmdbID int
		var mediaType, title, filePath string
		if err := rows.Scan(&id, &mediaType, &title, &filePath, &tmdbID); err != nil {
			continue
		}
		items = append(items, struct {
			id        int
			mediaType models.MediaType
			title     string
			filePath  string
			tmdbID    int
		}{id, models.MediaType(mediaType), title, filePath, tmdbID})
	}
	return items
}
