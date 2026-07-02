package indexer

import (
	"database/sql"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/subtitles"
)

var (
	IsScanning bool
	scanMutex  sync.Mutex
)

// Supported video extensions
var videoExtensions = map[string]bool{
	".mp4":  true,
	".mkv":  true,
	".avi":  true,
	".mov":  true,
	".wmv":  true,
	".flv":  true,
	".webm": true,
}

// Regex to parse Season and Episode pattern: S01E01, s1e1, S1E01, s01e01
var episodeRegex = regexp.MustCompile(`(?i)s(\d+)e(\d+)`)

// TMDB structures for API response parsing
type TMDBResponse struct {
	Results []struct {
		ID           int    `json:"id"`
		Title        string `json:"title"` // For movies
		Name         string `json:"name"`  // For TV shows
		Overview     string `json:"overview"`
		PosterPath   string `json:"poster_path"`
		ReleaseDate  string `json:"release_date"`   // For movies
		FirstAirDate string `json:"first_air_date"` // For TV shows
	} `json:"results"`
}

// ScanMedia starts the indexing process in a background thread if not already running
func ScanMedia(moviesDir, seriesDir string) {
	scanMutex.Lock()
	if IsScanning {
		scanMutex.Unlock()
		log.Println("Indexer: Scan is already in progress.")
		return
	}
	IsScanning = true
	scanMutex.Unlock()

	go func() {
		defer func() {
			scanMutex.Lock()
			IsScanning = false
			scanMutex.Unlock()
		}()

		log.Println("Indexer: Starting media scan...")
		startTime := time.Now()

		// Fix existing duplicate shows immediately (don't wait for a long filesystem walk).
		dedupeDuplicateShows()

		if err := scanMovies(moviesDir); err != nil {
			log.Printf("Indexer error scanning movies: %v", err)
		}

		if err := scanSeries(seriesDir); err != nil {
			log.Printf("Indexer error scanning series: %v", err)
		}

		dedupeDuplicateShows()
		dedupeDuplicateMovies()

		// Clean up broken database entries whose physical files have been deleted
		if err := cleanMissingMedias(); err != nil {
			log.Printf("Indexer error cleaning up missing medias: %v", err)
		}

		// Intro/outro detection is expensive (IntroDB + ffprobe) — run in the
		// background so /api/home and browsing stay responsive during startup.
		go DetectIntrosOutros()

		BackfillMissingMetadataAsync()

		log.Printf("Indexer: Media scan completed in %v", time.Since(startTime))
	}()
}

// scanMovies indexes all video files in the movies directory
func scanMovies(dir string) error {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		log.Printf("Indexer: Movies directory '%s' does not exist. Skipping.", dir)
		return nil
	}

	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if !videoExtensions[ext] {
			return nil
		}

		// Normalize paths for DB storage (using forward slashes)
		normalizedPath := filepath.ToSlash(path)

		// Check if already indexed
		var exists bool
		err = database.DB.QueryRow("SELECT EXISTS(SELECT 1 FROM medias WHERE file_path = ?)", normalizedPath).Scan(&exists)
		if err != nil {
			return err
		}
		if exists {
			return nil
		}

		// Parse movie title from filename (removing extension)
		rawTitle := strings.TrimSuffix(info.Name(), filepath.Ext(info.Name()))
		posterURL, overview, releaseDate, tmdbID, tmdbTitle := fetchTMDBMetadata(rawTitle, models.TypeMovie)
		displayTitle := tmdbTitle
		if displayTitle == "" {
			displayTitle = ReleaseDisplayTitle(rawTitle, models.TypeMovie)
		}

		// Insert movie with TMDB metadata
		res, err := database.DB.Exec(
			"INSERT INTO medias (type, title, file_path, duration, poster_url, overview, release_date, tmdb_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			models.TypeMovie, displayTitle, normalizedPath, 0, posterURL, overview, releaseDate, tmdbID,
		)
		if err != nil {
			log.Printf("Indexer: Failed to index movie %s: %v", displayTitle, err)
			return nil
		}

		log.Printf("Indexer: Successfully indexed Movie -> %s", displayTitle)

		if id, idErr := res.LastInsertId(); idErr == nil {
			extractSubtitles(int(id), normalizedPath)
		}
		return nil
	})
}

// scanSeries indexes TV shows, seasons, and episodes
func scanSeries(dir string) error {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		log.Printf("Indexer: Series directory '%s' does not exist. Skipping.", dir)
		return nil
	}

	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if !videoExtensions[ext] {
			return nil
		}

		normalizedPath := filepath.ToSlash(path)

		// Check if episode already indexed
		var exists bool
		err = database.DB.QueryRow("SELECT EXISTS(SELECT 1 FROM medias WHERE file_path = ?)", normalizedPath).Scan(&exists)
		if err != nil {
			return err
		}
		if exists {
			return nil // Already indexed, skip
		}

		// Parse show name, season, and episode
		// We can get the hierarchy relative to seriesDir
		relPath, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		parts := strings.Split(relPath, "/")

		var seasonNum int
		var episodeNum int

		// Match standard episode regex S01E01
		matches := episodeRegex.FindStringSubmatch(info.Name())
		if len(matches) < 3 {
			// Skip files that do not have SxxExx in their name
			return nil
		}

		sNum, _ := strconv.Atoi(matches[1])
		eNum, _ := strconv.Atoi(matches[2])
		seasonNum = sNum
		episodeNum = eNum

		// Determine show title from folder layout (handles per-episode download folders).
		showTitle := resolveShowTitleFromPath(parts, info.Name())

		// Find or Create Show
		showID, err := findOrCreateShow(showTitle)
		if err != nil {
			log.Printf("Indexer error: failed to resolve show %s: %v", showTitle, err)
			return nil
		}

		// Find or Create Season
		seasonID, err := findOrCreateSeason(showID, seasonNum)
		if err != nil {
			log.Printf("Indexer error: failed to resolve season %d for show %s: %v", seasonNum, showTitle, err)
			return nil
		}

		showTMDBID := lookupShowTMDBID(showID)
		epTitle := fallbackEpisodeTitle(seasonNum, episodeNum)
		epOverview := ""
		epPoster := getShowPosterForSeason(seasonID)
		epAirDate := ""
		epTMDBID := 0

		if showTMDBID > 0 {
			tmdbTitle, tmdbOverview, tmdbPoster, tmdbAirDate, tmdbEpID := fetchTMDBEpisode(showTMDBID, seasonNum, episodeNum)
			if tmdbTitle != "" {
				epTitle = tmdbTitle
			}
			epOverview = tmdbOverview
			if tmdbPoster != "" {
				epPoster = tmdbPoster
			}
			epAirDate = tmdbAirDate
			epTMDBID = tmdbEpID
		}

		res, err := database.DB.Exec(
			`INSERT INTO medias (type, title, file_path, duration, parent_id, poster_url, overview, release_date, tmdb_id, season_number, episode_number)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			models.TypeEpisode, epTitle, normalizedPath, 0, seasonID, epPoster, epOverview, epAirDate, epTMDBID, seasonNum, episodeNum,
		)
		if err != nil {
			log.Printf("Indexer: Failed to index episode %s: %v", epTitle, err)
			return nil
		}

		log.Printf("Indexer: Successfully indexed Episode -> %s (S%02dE%02d)", showTitle, seasonNum, episodeNum)

		if id, idErr := res.LastInsertId(); idErr == nil {
			extractSubtitles(int(id), normalizedPath)
		}
		return nil
	})
}

// findOrCreateSeason gets the ID of a season or creates it under a show
func findOrCreateSeason(showID int, seasonNum int) (int, error) {
	seasonTitle := "Saison " + strconv.Itoa(seasonNum)
	var id int
	err := database.DB.QueryRow(
		"SELECT id FROM medias WHERE type = ? AND parent_id = ? AND title = ?",
		models.TypeSeason, showID, seasonTitle,
	).Scan(&id)
	if err == nil {
		_, _ = database.DB.Exec(
			"UPDATE medias SET season_number = ? WHERE id = ? AND (season_number IS NULL OR season_number = 0)",
			seasonNum, id,
		)
		return id, nil
	}
	if err != sql.ErrNoRows {
		return 0, err
	}

	// Insert Season
	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, ?, ?, ?)",
		models.TypeSeason, seasonTitle, showID, seasonNum,
	)
	if err != nil {
		return 0, err
	}

	insertID, err := res.LastInsertId()
	return int(insertID), err
}

// extractSubtitles pre-extracts every text subtitle track from the freshly
// indexed file into .vtt sidecars and registers them in the database. Failures
// are non-fatal: a media without (text) subtitles is perfectly valid.
func extractSubtitles(mediaID int, filePath string) {
	if err := subtitles.ExtractAndRegister(mediaID, filePath); err != nil {
		log.Printf("Indexer: subtitle extraction failed for media %d: %v", mediaID, err)
	}
}

// cleanMissingMedias removes items from the DB if their physical files are gone
func cleanMissingMedias() error {
	rows, err := database.DB.Query("SELECT id, title, file_path, type FROM medias WHERE file_path IS NOT NULL AND file_path != ''")
	if err != nil {
		return err
	}
	defer rows.Close()

	type item struct {
		id        int
		title     string
		filePath  string
		mediaType string
	}

	var itemsToDelete []item

	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.title, &it.filePath, &it.mediaType); err != nil {
			return err
		}

		// Verify if file still exists on disk
		if _, err := os.Stat(it.filePath); os.IsNotExist(err) {
			itemsToDelete = append(itemsToDelete, it)
		}
	}

	for _, it := range itemsToDelete {
		log.Printf("Indexer: Physical file missing, deleting media %s from database (Path: %s)", it.title, it.filePath)
		_, err := database.DB.Exec("DELETE FROM medias WHERE id = ?", it.id)
		if err != nil {
			log.Printf("Indexer: Error deleting orphaned media: %v", err)
		}

		// If it's an episode, check if we should delete parent seasons/shows that might now be empty
		if it.mediaType == string(models.TypeEpisode) {
			// SQLite cascading deletion handles deleting children, but we might have empty seasons/shows left
			cleanEmptySeasonsAndShows()
		}
	}

	return nil
}

// cleanEmptySeasonsAndShows deletes seasons with no episodes, and shows with no seasons
func cleanEmptySeasonsAndShows() {
	// 1. Delete seasons with no episodes
	_, err := database.DB.Exec(`
		DELETE FROM medias 
		WHERE type = 'season' 
		AND id NOT IN (SELECT DISTINCT parent_id FROM medias WHERE type = 'episode' AND parent_id IS NOT NULL)
	`)
	if err != nil {
		log.Printf("Indexer cleanup error (seasons): %v", err)
	}

	// 2. Delete shows with no seasons
	_, err = database.DB.Exec(`
		DELETE FROM medias 
		WHERE type = 'show' 
		AND id NOT IN (SELECT DISTINCT parent_id FROM medias WHERE type = 'season' AND parent_id IS NOT NULL)
	`)
	if err != nil {
		log.Printf("Indexer cleanup error (shows): %v", err)
	}
}

