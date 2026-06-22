package indexer

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/models"
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
		Title        string `json:"title"`          // For movies
		Name         string `json:"name"`           // For TV shows
		Overview     string `json:"overview"`
		PosterPath   string `json:"poster_path"`
		ReleaseDate  string `json:"release_date"`   // For movies
		FirstAirDate string `json:"first_air_date"` // For TV shows
	} `json:"results"`
}

// fetchTMDBMetadata queries TMDB API to get poster, plot, and other metadata
func fetchTMDBMetadata(title string, mediaType models.MediaType) (posterURL string, overview string, releaseDate string, tmdbID int) {
	apiKey := os.Getenv("TMDB_API_KEY")
	if apiKey == "" {
		return "", "", "", 0 // Skip if no API key is provided
	}

	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}

	apiURL := fmt.Sprintf(
		"https://api.themoviedb.org/3/search/%s?api_key=%s&query=%s&language=fr-FR", // Preferred French metadata
		endpoint,
		apiKey,
		url.QueryEscape(title),
	)

	// Fallback to English if query is made, but let's default to French
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(apiURL)
	if err != nil {
		log.Printf("TMDB: Failed to fetch metadata for %s: %v", title, err)
		return "", "", "", 0
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Try again in English if French fails or has some error, or just return
		return "", "", "", 0
	}

	var tmdbResp TMDBResponse
	if err := json.NewDecoder(resp.Body).Decode(&tmdbResp); err != nil {
		log.Printf("TMDB: Failed to decode response for %s: %v", title, err)
		return "", "", "", 0
	}

	if len(tmdbResp.Results) == 0 {
		// Retry without language tag (defaults to English) if no results found
		apiURL = fmt.Sprintf(
			"https://api.themoviedb.org/3/search/%s?api_key=%s&query=%s",
			endpoint,
			apiKey,
			url.QueryEscape(title),
		)
		resp2, err := client.Get(apiURL)
		if err == nil {
			defer resp2.Body.Close()
			_ = json.NewDecoder(resp2.Body).Decode(&tmdbResp)
		}
	}

	if len(tmdbResp.Results) > 0 {
		result := tmdbResp.Results[0]
		tmdbID = result.ID
		overview = result.Overview

		if result.PosterPath != "" {
			posterURL = "https://image.tmdb.org/t/p/w500" + result.PosterPath
		}

		if mediaType == models.TypeShow {
			releaseDate = result.FirstAirDate
		} else {
			releaseDate = result.ReleaseDate
		}

		return posterURL, overview, releaseDate, tmdbID
	}

	return "", "", "", 0
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

		if err := scanMovies(moviesDir); err != nil {
			log.Printf("Indexer error scanning movies: %v", err)
		}

		if err := scanSeries(seriesDir); err != nil {
			log.Printf("Indexer error scanning series: %v", err)
		}

		// Clean up broken database entries whose physical files have been deleted
		if err := cleanMissingMedias(); err != nil {
			log.Printf("Indexer error cleaning up missing medias: %v", err)
		}

		// Run intro and outro detection
		DetectIntrosOutros()

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
			return nil // Already indexed, skip
		}

		// Parse movie title from filename (removing extension)
		title := strings.TrimSuffix(info.Name(), filepath.Ext(info.Name()))
		// Optional: clean up standard scene tags in names
		title = cleanTitle(title)

		// Fetch TMDB Metadata
		posterURL, overview, releaseDate, tmdbID := fetchTMDBMetadata(title, models.TypeMovie)

		// Insert movie with TMDB metadata
		_, err = database.DB.Exec(
			"INSERT INTO medias (type, title, file_path, duration, poster_url, overview, release_date, tmdb_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			models.TypeMovie, title, normalizedPath, 0, posterURL, overview, releaseDate, tmdbID,
		)
		if err != nil {
			log.Printf("Indexer: Failed to index movie %s: %v", title, err)
			return nil
		}

		log.Printf("Indexer: Successfully indexed Movie -> %s", title)
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

		var showTitle string
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

		// Determine Show Title
		// If nested in folders: /Series/Breaking Bad/Season 1/S01E01.mkv
		if len(parts) >= 2 {
			showTitle = parts[0] // "Breaking Bad"
		} else {
			// Flat folder: /Series/Breaking Bad S01E01.mkv
			// Take everything before S01E01
			loc := episodeRegex.FindStringIndex(info.Name())
			if loc != nil {
				showTitle = info.Name()[:loc[0]]
				showTitle = strings.Trim(showTitle, " -_")
			} else {
				showTitle = "Unknown Show"
			}
		}
		showTitle = cleanTitle(showTitle)

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

		// Build Episode Title: e.g. "S01E03 - Title" or just "Episode 3"
		epTitle := strings.TrimSuffix(info.Name(), filepath.Ext(info.Name()))
		epTitle = cleanTitle(epTitle)

		// Create Episode
		_, err = database.DB.Exec(
			"INSERT INTO medias (type, title, file_path, duration, parent_id, poster_url) VALUES (?, ?, ?, ?, ?, ?)",
			models.TypeEpisode, epTitle, normalizedPath, 0, seasonID, "",
		)
		if err != nil {
			log.Printf("Indexer: Failed to index episode %s: %v", epTitle, err)
			return nil
		}

		log.Printf("Indexer: Successfully indexed Episode -> %s (S%02dE%02d)", showTitle, seasonNum, episodeNum)
		return nil
	})
}

// findOrCreateShow gets the ID of a show by title or creates it if it doesn't exist
func findOrCreateShow(title string) (int, error) {
	var id int
	err := database.DB.QueryRow("SELECT id FROM medias WHERE type = ? AND title = ?", models.TypeShow, title).Scan(&id)
	if err == nil {
		return id, nil
	}
	if err != sql.ErrNoRows {
		return 0, err
	}

	// Fetch TMDB Metadata for TV Show
	posterURL, overview, releaseDate, tmdbID := fetchTMDBMetadata(title, models.TypeShow)

	// Insert Show with TMDB metadata
	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, poster_url, overview, release_date, tmdb_id) VALUES (?, ?, ?, ?, ?, ?)",
		models.TypeShow, title, posterURL, overview, releaseDate, tmdbID,
	)
	if err != nil {
		return 0, err
	}

	insertID, err := res.LastInsertId()
	return int(insertID), err
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
		return id, nil
	}
	if err != sql.ErrNoRows {
		return 0, err
	}

	// Insert Season
	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, parent_id) VALUES (?, ?, ?)",
		models.TypeSeason, seasonTitle, showID,
	)
	if err != nil {
		return 0, err
	}

	insertID, err := res.LastInsertId()
	return int(insertID), err
}

// cleanMissingMedias removes items from the DB if their physical files are gone
func cleanMissingMedias() error {
	rows, err := database.DB.Query("SELECT id, title, file_path, type FROM medias WHERE file_path IS NOT NULL AND file_path != ''")
	if err != nil {
		return err
	}
	defer rows.Close()

	type item struct {
		id       int
		title    string
		filePath string
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

// cleanTitle removes common scene noise, release tags, or extensions from titles
func cleanTitle(title string) string {
	// Replaces dots and underscores with spaces
	title = strings.ReplaceAll(title, ".", " ")
	title = strings.ReplaceAll(title, "_", " ")

	// Common scene noise patterns to truncate title at
	noiseRegex := regexp.MustCompile(`(?i)(1080p|720p|2160p|4k|bluray|web-dl|webrip|h264|h265|x264|x265|multi|vostfr|french|dvdrip|mkv)`)
	loc := noiseRegex.FindStringIndex(title)
	if loc != nil {
		title = title[:loc[0]]
	}

	return strings.TrimSpace(title)
}
