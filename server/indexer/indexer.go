package indexer

import (
	"database/sql"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

// scanning guards the single background scan. It is read from the HTTP
// handlers (scan status, trigger) while the scan goroutine writes it, so it has
// to be atomic: the previous bool-plus-mutex pair only locked on the write side
// and left every reader racing.
var scanning atomic.Bool

// IsScanning reports whether a media scan is currently running.
func IsScanning() bool { return scanning.Load() }

// Regex to parse Season and Episode pattern: S01E01, s1e1, S1E01, s01e01
var episodeRegex = regexp.MustCompile(`(?i)s(\d+)e(\d+)`)

// TMDB structures for API response parsing
type TMDBResponse struct {
	Results []struct {
		ID            int     `json:"id"`
		Title         string  `json:"title"` // For movies
		Name          string  `json:"name"`  // For TV shows
		OriginalTitle string  `json:"original_title"`
		OriginalName  string  `json:"original_name"`
		Overview      string  `json:"overview"`
		PosterPath    string  `json:"poster_path"`
		ReleaseDate   string  `json:"release_date"`   // For movies
		FirstAirDate  string  `json:"first_air_date"` // For TV shows
		Popularity    float64 `json:"popularity"`
	} `json:"results"`
}

// ScanMedia starts the indexing process in a background thread if not already
// running. It reports whether this call is the one that started it, so a caller
// answering an HTTP request can say "already running" without a check-then-act
// race against another request.
func ScanMedia(moviesDir, seriesDir string) bool {
	if !scanning.CompareAndSwap(false, true) {
		log.Println("Indexer: Scan is already in progress.")
		return false
	}

	go func() {
		defer scanning.Store(false)

		log.Println("Indexer: Starting media scan...")
		startTime := time.Now()
		ResetDirScanCache()
		ResetSearchCache()
		beginScanReport(moviesDir, seriesDir)
		defer finishScanReport()

		// Fix existing duplicate shows immediately (don't wait for a long filesystem walk).
		dedupeDuplicateShows()

		scanMovies(moviesDir)
		scanSeries(seriesDir)

		// Repair episodes filed under the wrong show by an older scan.
		RelinkEpisodesToShows(seriesDir)

		dedupeDuplicateShows()
		dedupeDuplicateMovies()
		// Heal films that an earlier scan pinned to the wrong TMDB entry.
		RedetectAmbiguousMovies()

		// Clean up broken database entries whose physical files have been deleted
		if err := cleanMissingMedias(moviesDir, seriesDir); err != nil {
			log.Printf("Indexer error cleaning up missing medias: %v", err)
		}

		logScanSummary()

		InvalidateStreamCaches()
		BackfillMissingProbesAsync()

		// Intro/outro detection is expensive (IntroDB + ffprobe) — run in the
		// background so /api/home and browsing stay responsive during startup.
		go DetectIntrosOutros()

		BackfillMissingMetadataAsync()

		log.Printf("Indexer: Media scan completed in %v", time.Since(startTime))
	}()

	return true
}

func nullIfEmpty(s string) interface{} {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return s
}

// scanMovies indexes all video files in the movies directory
func scanMovies(dir string) {
	if _, err := os.Stat(dir); err != nil {
		log.Printf("Indexer: Movies directory '%s' is not reachable (%v). Skipping.", dir, err)
		reportError("dossier films inaccessible: %s (%v)", dir, err)
		return
	}

	walkVideoFiles(dir, sectionMovies, func(path string, info os.FileInfo) {
		// Normalize paths for DB storage (using forward slashes)
		normalizedPath := filepath.ToSlash(path)

		// Check if already indexed
		var exists bool
		if err := database.DB.QueryRow(
			"SELECT EXISTS(SELECT 1 FROM medias WHERE file_path = ?)", normalizedPath,
		).Scan(&exists); err != nil {
			log.Printf("Indexer: lookup failed for %s: %v", normalizedPath, err)
			reportError("lecture base impossible pour %s (%v)", normalizedPath, err)
			return
		}
		if exists {
			reportAlreadyIndexed(sectionMovies)
			return
		}

		// Emby-style identity: folder/NFO/provider IDs first, then confident TMDB match.
		identity := IdentifyMovie(path, dir)
		displayTitle := identity.Title
		if displayTitle == "" {
			displayTitle = ReleaseDisplayTitle(ResolveMovieLookupName(path, dir), models.TypeMovie)
		}
		if displayTitle == "" {
			displayTitle = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		}
		tmdbID := 0
		if identity.Matched {
			tmdbID = identity.TMDBID
		}

		res, err := database.DB.Exec(
			"INSERT INTO medias (type, title, file_path, duration, file_size, poster_url, overview, release_date, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			models.TypeMovie, displayTitle, normalizedPath, 0, info.Size(), identity.PosterURL, identity.Overview, identity.ReleaseDate, tmdbID, nullIfEmpty(identity.IMDbID),
		)
		if err != nil {
			log.Printf("Indexer: Failed to index movie %s: %v", displayTitle, err)
			reportFailed(sectionMovies)
			reportError("insertion impossible pour %s (%v)", normalizedPath, err)
			return
		}

		reportIndexed(sectionMovies, identity.Matched)
		if identity.Matched {
			log.Printf("Indexer: Indexed Movie -> %s (tmdb=%d via %s, conf=%.2f)", displayTitle, tmdbID, identity.Source, identity.Confidence)
		} else {
			log.Printf("Indexer: Indexed Movie -> %s (unmatched — needs review)", displayTitle)
			reportUnmatched(normalizedPath, displayTitle, string(models.TypeMovie))
		}

		if id, idErr := res.LastInsertId(); idErr == nil {
			ProbeAndPersist(int(id), displayTitle, normalizedPath, info.Size(), info.ModTime())
		}
	})
}

// scanSeries indexes TV shows, seasons, and episodes
func scanSeries(dir string) {
	if _, err := os.Stat(dir); err != nil {
		log.Printf("Indexer: Series directory '%s' is not reachable (%v). Skipping.", dir, err)
		reportError("dossier séries inaccessible: %s (%v)", dir, err)
		return
	}

	walkVideoFiles(dir, sectionSeries, func(path string, info os.FileInfo) {
		normalizedPath := filepath.ToSlash(path)

		// Check if episode already indexed
		var exists bool
		if err := database.DB.QueryRow(
			"SELECT EXISTS(SELECT 1 FROM medias WHERE file_path = ?)", normalizedPath,
		).Scan(&exists); err != nil {
			log.Printf("Indexer: lookup failed for %s: %v", normalizedPath, err)
			reportError("lecture base impossible pour %s (%v)", normalizedPath, err)
			return
		}
		if exists {
			reportAlreadyIndexed(sectionSeries)
			return // Already indexed, skip
		}

		// Parse show name, season, and episode
		// We can get the hierarchy relative to seriesDir
		relPath, err := filepath.Rel(dir, path)
		if err != nil {
			reportSkipped(sectionSeries, normalizedPath, "chemin hors bibliothèque")
			return
		}
		relPath = filepath.ToSlash(relPath)
		parts := strings.Split(relPath, "/")

		// Emby-compatible episode patterns (SxxExx, 1x02, Season/Episode, …),
		// falling back to the folder layout for bare "01 - Title.mkv" episodes.
		seasonNum, episodeNum, ok := ResolveEpisodeNumbers(parts, info.Name())
		if !ok {
			reportSkipped(sectionSeries, normalizedPath, "numéro de saison/épisode introuvable dans le nom")
			return
		}

		// Determine show title from folder layout (handles per-episode download folders).
		showTitle := resolveShowTitleFromPath(parts, info.Name())
		tmdbSearchKey := resolveShowTMDBSearchKeyFromPath(parts, info.Name())
		showFolderPath := resolveShowFolderPath(dir, parts)

		// Find or Create Show (local IDs/NFO before TMDB search)
		showID, err := findOrCreateShow(showTitle, tmdbSearchKey, showFolderPath)
		if err != nil {
			log.Printf("Indexer error: failed to resolve show %s: %v", showTitle, err)
			reportFailed(sectionSeries)
			reportError("série non résolue pour %s (%v)", normalizedPath, err)
			return
		}

		// Find or Create Season
		seasonID, err := findOrCreateSeason(showID, seasonNum)
		if err != nil {
			log.Printf("Indexer error: failed to resolve season %d for show %s: %v", seasonNum, showTitle, err)
			reportFailed(sectionSeries)
			return
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
			`INSERT INTO medias (type, title, file_path, duration, file_size, parent_id, poster_url, overview, release_date, tmdb_id, season_number, episode_number)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			models.TypeEpisode, epTitle, normalizedPath, 0, info.Size(), seasonID, epPoster, epOverview, epAirDate, epTMDBID, seasonNum, episodeNum,
		)
		if err != nil {
			log.Printf("Indexer: Failed to index episode %s: %v", epTitle, err)
			reportFailed(sectionSeries)
			reportError("insertion impossible pour %s (%v)", normalizedPath, err)
			return
		}

		reportIndexed(sectionSeries, showTMDBID > 0)
		if showTMDBID <= 0 {
			reportUnmatched(normalizedPath, showTitle, string(models.TypeEpisode))
		}
		log.Printf("Indexer: Successfully indexed Episode -> %s (S%02dE%02d)", showTitle, seasonNum, episodeNum)

		if id, idErr := res.LastInsertId(); idErr == nil {
			ProbeAndPersist(int(id), epTitle, normalizedPath, info.Size(), info.ModTime())
		}
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

// Subtitles are deliberately NOT extracted here. Extracting one is a full
// sequential read of the container, so doing it for every file during a scan
// dominates the scan's cost — on a library of large remuxes it is hours of I/O.
//
// Nothing is lost by skipping it: ProbeAndPersist already records every subtitle
// stream in tracks_json, so subtitles.Catalog lists all languages in the UI
// straight away. The .vtt itself is produced on demand at first playback by
// subtitles.EnsureExtractedSync, which reads the file once for all tracks.

// cleanMissingMedias removes items from the DB if their physical files are gone.
//
// It refuses to run when a library root is unreachable, and bails out when the
// deletion would wipe a large share of the library: an unmounted NAS or a
// network hiccup must not empty the catalog.
func cleanMissingMedias(roots ...string) error {
	for _, root := range roots {
		if strings.TrimSpace(root) == "" {
			continue
		}
		if _, err := os.Stat(root); err != nil {
			log.Printf("Indexer: skipping cleanup — library root %s is unreachable (%v)", root, err)
			reportError("nettoyage annulé: racine %s inaccessible (%v)", root, err)
			return nil
		}
	}

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
	total := 0

	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.title, &it.filePath, &it.mediaType); err != nil {
			return err
		}
		total++

		// Verify if file still exists on disk. Only a definitive "not found"
		// deletes: permission errors or I/O timeouts leave the entry alone.
		if _, err := os.Stat(it.filePath); err != nil {
			if !os.IsNotExist(err) {
				log.Printf("Indexer: keeping %s — cannot stat file (%v)", it.filePath, err)
				continue
			}
			itemsToDelete = append(itemsToDelete, it)
		}
	}
	rows.Close()

	if len(itemsToDelete) > 20 && total > 0 && float64(len(itemsToDelete)) > 0.25*float64(total) {
		log.Printf("Indexer: SAFETY — refusing to delete %d/%d entries (storage probably offline)", len(itemsToDelete), total)
		reportError("nettoyage annulé: %d/%d fichiers introuvables, stockage probablement hors ligne", len(itemsToDelete), total)
		return nil
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

// logScanSummary prints the file-vs-library accounting so a gap between "510
// files on disk" and "489 items in the app" is explainable, not a mystery.
func logScanSummary() {
	report := LastScanReport()
	for _, s := range []ScanSectionStats{report.Movies, report.Series} {
		log.Printf(
			"Indexer: %s — %d fichier(s) vidéo, %d déjà indexé(s), %d nouveau(x) (%d identifié(s), %d sans correspondance TMDB), %d fichier(s) ignoré(s), %d dossier(s) ignoré(s), %d échec(s)",
			s.Root, s.VideoFiles, s.AlreadyIndexed, s.Indexed, s.Matched, s.Unmatched, s.Skipped, s.SkippedFolders, s.Failed,
		)
	}
	if len(report.Errors) > 0 {
		log.Printf("Indexer: %d erreur(s) pendant le scan — voir GET /api/indexer/report", len(report.Errors))
	}
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

