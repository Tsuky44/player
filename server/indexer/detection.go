package indexer

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
)

// ChapterItem represents a simplified chapter structure
type ChapterItem struct {
	ID        int     `json:"id"`
	StartTime float64 `json:"start_time"`
	EndTime   float64 `json:"end_time"`
	Title     string  `json:"title"`
}

// Keywords for matching intro and outro chapters (multi-word only; short tokens
// like "op"/"ed" use exact-token matching to avoid false positives).
var introKeywords = []string{
	"intro", "opening", "recap", "previously on",
	"generique de debut", "generique debut",
}
var outroKeywords = []string{
	"outro", "ending", "crédits",
	"generique de fin", "generique fin", "generique de fin",
}

// isOpeningCreditsChapter matches Plex/Jellyfin-style opening credit markers.
func isOpeningCreditsChapter(normTitle string) bool {
	if normTitle == "" {
		return false
	}
	if strings.Contains(normTitle, "opencreditstart") || strings.Contains(normTitle, "open_credit_start") {
		return true
	}
	if strings.Contains(normTitle, "open") && strings.Contains(normTitle, "credit") && strings.Contains(normTitle, "start") {
		return true
	}
	if strings.Contains(normTitle, "opening") && strings.Contains(normTitle, "credit") {
		return true
	}
	return false
}

// isClosingCreditsChapter matches end-credit chapters without false positives on
// openCreditStart / openCreditEnd style names.
func isClosingCreditsChapter(normTitle string) bool {
	if normTitle == "" {
		return false
	}
	if isOpeningCreditsChapter(normTitle) {
		return false
	}
	if strings.Contains(normTitle, "open") && strings.Contains(normTitle, "credit") {
		return false
	}
	if normTitle == "credits" || normTitle == "credit" {
		return true
	}
	if strings.Contains(normTitle, "credits") {
		return true
	}
	return false
}

// IsPlausibleIntroRange rejects chapter/DB values that span most of an episode.
func IsPlausibleIntroRange(start, end, mediaDuration int) bool {
	if end <= start || end <= 0 {
		return false
	}
	if end-start > 600 {
		return false
	}
	if mediaDuration > 0 && end > int(float64(mediaDuration)*0.85) {
		return false
	}
	return true
}

func titleMatchesKeyword(normTitle, keyword string) bool {
	if keyword == "op" || keyword == "ed" {
		if normTitle == keyword {
			return true
		}
		return strings.HasPrefix(normTitle, keyword+" ") || strings.HasSuffix(normTitle, " "+keyword)
	}
	return strings.Contains(normTitle, keyword)
}

// ChapterTitleMatchesIntro detects intro/recap chapter titles from MKV metadata.
func ChapterTitleMatchesIntro(title string) bool {
	normTitle := normalizeString(title)
	if normTitle == "" {
		return false
	}
	if isOpeningCreditsChapter(normTitle) {
		return true
	}
	for _, kw := range introKeywords {
		if titleMatchesKeyword(normTitle, kw) {
			return true
		}
	}
	return titleMatchesKeyword(normTitle, "op")
}

// ChapterTitleMatchesOutro detects outro/credits chapter titles from MKV metadata.
func ChapterTitleMatchesOutro(title string) bool {
	normTitle := normalizeString(title)
	if normTitle == "" {
		return false
	}
	if isClosingCreditsChapter(normTitle) {
		return true
	}
	for _, kw := range outroKeywords {
		if titleMatchesKeyword(normTitle, kw) {
			return true
		}
	}
	return titleMatchesKeyword(normTitle, "ed")
}

// MergeIntroDBSkipRange builds the skippable window from IntroDB intro + recap.
func MergeIntroDBSkipRange(intro, recap *IntroDBSegment) (start, end int, ok bool) {
	if recap != nil {
		start = int(recap.StartSec)
		end = int(recap.EndSec)
		ok = true
	}
	if intro != nil {
		iStart := int(intro.StartSec)
		iEnd := int(intro.EndSec)
		if !ok {
			start, end, ok = iStart, iEnd, true
		} else {
			if iStart < start {
				start = iStart
			}
			end = iEnd
		}
	}
	return start, end, ok
}

// TheIntroDB API structures
type IntroDBSegment struct {
	StartMs          int     `json:"start_ms"`
	EndMs            int     `json:"end_ms"`
	StartSec         float64 `json:"start_sec"`
	EndSec           float64 `json:"end_sec"`
	Confidence       float64 `json:"confidence"`
	SubmissionCount  int     `json:"submission_count"`
}

type IntroDBResponse struct {
	IMDbID  string          `json:"imdb_id"`
	Season  int             `json:"season"`
	Episode int             `json:"episode"`
	Intro   *IntroDBSegment `json:"intro"`
	Recap   *IntroDBSegment `json:"recap"`
	Outro   *IntroDBSegment `json:"outro"`
}

// TMDBExternalIDs represents the external IDs response from TMDB API
type TMDBExternalIDs struct {
	IMDbID string `json:"imdb_id"`
}

// GetIMDbIDFromTMDB converts a TMDB ID to IMDb ID using TMDB API
func GetIMDbIDFromTMDB(tmdbID int) (string, error) {
	apiKey := tmdbAPIKey()
	if apiKey == "" {
		return "", fmt.Errorf("TMDB_API_KEY not set")
	}

	url := fmt.Sprintf("https://api.themoviedb.org/3/tv/%d/external_ids?api_key=%s", tmdbID, apiKey)
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("failed to fetch TMDB external IDs: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("TMDB API returned status %d", resp.StatusCode)
	}

	var externalIDs TMDBExternalIDs
	if err := json.NewDecoder(resp.Body).Decode(&externalIDs); err != nil {
		return "", fmt.Errorf("failed to decode TMDB response: %v", err)
	}

	if externalIDs.IMDbID == "" {
		return "", fmt.Errorf("no IMDb ID found for TMDB ID %d", tmdbID)
	}

	return externalIDs.IMDbID, nil
}

// FetchSegmentsFromIntroDB fetches intro/recap/outro segments from TheIntroDB API
func FetchSegmentsFromIntroDB(imdbID string, season, episode int) (*IntroDBResponse, error) {
	url := fmt.Sprintf("https://api.introdb.app/segments?imdb_id=%s&season=%d&episode=%d", imdbID, season, episode)
	resp, err := http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch from IntroDB: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, nil // No data found, not an error
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("IntroDB API returned status %d", resp.StatusCode)
	}

	var result IntroDBResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode IntroDB response: %v", err)
	}

	return &result, nil
}

// Normalize string for keyword matching
func normalizeString(s string) string {
	s = strings.ToLower(s)
	// Simple accent stripping
	replacer := strings.NewReplacer(
		"é", "e", "è", "e", "ê", "e", "ë", "e",
		"à", "a", "â", "a", "ä", "a",
		"î", "i", "ï", "i",
		"ô", "o", "ö", "o",
		"û", "u", "ü", "u", "ù", "u",
		"ç", "c",
	)
	s = replacer.Replace(s)
	return strings.TrimSpace(s)
}

// DetectFromChapters attempts to discover intro/outro points using video chapters
func DetectFromChapters(episodeID int, filePath string) (bool, error) {
	if filePath == "" {
		return false, fmt.Errorf("empty file path")
	}

	// Run ffprobe to get chapters
	cmd := exec.Command("ffprobe", "-v", "quiet", "-print_format", "json", "-show_chapters", filePath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		return false, fmt.Errorf("ffprobe failed: %v, stderr: %s", err, stderr.String())
	}

	var ffResponse struct {
		Chapters []struct {
			ID        int                    `json:"id"`
			StartTime string                 `json:"start_time"`
			EndTime   string                 `json:"end_time"`
			Tags      map[string]interface{} `json:"tags"`
		} `json:"chapters"`
	}

	if err := json.Unmarshal(stdout.Bytes(), &ffResponse); err != nil {
		return false, err
	}

	if len(ffResponse.Chapters) == 0 {
		return false, nil // No chapters found
	}

	var introStart, introEnd, outroStart, outroEnd int
	foundIntro := false
	foundOutro := false

	for _, c := range ffResponse.Chapters {
		start, _ := strconv.ParseFloat(c.StartTime, 64)
		end, _ := strconv.ParseFloat(c.EndTime, 64)

		title := ""
		if c.Tags != nil {
			if t, ok := c.Tags["title"]; ok {
				title = fmt.Sprintf("%v", t)
			} else if t, ok := c.Tags["TITLE"]; ok {
				title = fmt.Sprintf("%v", t)
			}
		}

		if title == "" {
			continue
		}

		iStart := int(start)
		iEnd := int(end)

		if ChapterTitleMatchesIntro(title) {
			if !foundIntro || iStart < introStart {
				if IsPlausibleIntroRange(iStart, iEnd, 0) {
					introStart = iStart
					introEnd = iEnd
					foundIntro = true
				}
			}
		}

		if ChapterTitleMatchesOutro(title) {
			if !foundOutro || iStart > outroStart {
				outroStart = iStart
				outroEnd = iEnd
				foundOutro = true
			}
		}
	}

	if foundIntro || foundOutro {
		// Update database
		_, err := database.DB.Exec(
			"UPDATE medias SET intro_start = ?, intro_end = ?, outro_start = ?, outro_end = ? WHERE id = ?",
			introStart, introEnd, outroStart, outroEnd, episodeID,
		)
		if err != nil {
			return false, fmt.Errorf("failed to save chapters timestamps: %v", err)
		}
		log.Printf("Detection: Found chapter-based markers for episode %d -> Intro: [%d-%d], Outro: [%d-%d]",
			episodeID, introStart, introEnd, outroStart, outroEnd)
		return true, nil
	}

	return false, nil
}

// DetectIntrosOutros coordinates the global detection process
func DetectIntrosOutros() {
	log.Println("Detection: Analyzing episodes for intros and outros...")

	// 1. Get all seasons that have unanalyzed episodes
	rows, err := database.DB.Query(`
		SELECT DISTINCT parent_id
		FROM medias
		WHERE type = 'episode'
		  AND (intro_end = 0 AND outro_start = 0)
	`)
	if err != nil {
		log.Printf("Detection error: failed to query seasons: %v", err)
		return
	}
	defer rows.Close()

	var seasonIDs []int
	for rows.Next() {
		var sID int
		if err := rows.Scan(&sID); err == nil {
			seasonIDs = append(seasonIDs, sID)
		}
	}
	rows.Close()

	for _, seasonID := range seasonIDs {
		log.Printf("Detection: Starting analysis for Season ID %d...", seasonID)
		if err := AnalyzeSeason(seasonID); err != nil {
			log.Printf("Detection error on Season ID %d: %v", seasonID, err)
		}
	}
	log.Println("Detection: Process completed.")
}

// DetectIntrosOutrosForShow triggers detection for a specific show (all its seasons)
// Returns detailed results for each episode
func DetectIntrosOutrosForShow(showID int) ([]map[string]interface{}, error) {
	log.Printf("Detection: Starting intro/outro detection for show ID %d...", showID)

	// Get all seasons for this show
	query := `
		SELECT id, title
		FROM medias
		WHERE type = 'season' AND parent_id = ?
		ORDER BY id
	`
	rows, err := database.DB.Query(query, showID)
	if err != nil {
		return nil, fmt.Errorf("failed to query seasons for show: %v", err)
	}
	defer rows.Close()

	type SeasonInfo struct {
		ID    int
		Title string
	}
	seasons := []SeasonInfo{}
	for rows.Next() {
		var s SeasonInfo
		if err := rows.Scan(&s.ID, &s.Title); err != nil {
			log.Printf("Detection: Failed to scan season: %v", err)
			continue
		}
		seasons = append(seasons, s)
	}

	results := []map[string]interface{}{}
	for _, season := range seasons {
		// Reset intro/outro for this season's episodes before re-detecting
		_, _ = database.DB.Exec(`
			UPDATE medias
			SET intro_start = 0, intro_end = 0, outro_start = 0, outro_end = 0
			WHERE type = 'episode' AND parent_id = ?
		`, season.ID)

		// Run detection
		if err := AnalyzeSeason(season.ID); err != nil {
			log.Printf("Detection error on Season ID %d: %v", season.ID, err)
			results = append(results, map[string]interface{}{
				"season_id":    season.ID,
				"season_title": season.Title,
				"error":        err.Error(),
			})
			continue
		}

		// Get results for this season
		episodesQuery := `
			SELECT id, title, intro_start, intro_end, outro_start, outro_end
			FROM medias
			WHERE type = 'episode' AND parent_id = ?
			ORDER BY id
		`
		epRows, err := database.DB.Query(episodesQuery, season.ID)
		if err != nil {
			log.Printf("Detection: Failed to query episode results: %v", err)
			continue
		}

		episodeResults := []map[string]interface{}{}
		for epRows.Next() {
			var id, introStart, introEnd, outroStart, outroEnd int
			var title string
			if err := epRows.Scan(&id, &title, &introStart, &introEnd, &outroStart, &outroEnd); err != nil {
				continue
			}
			episodeResults = append(episodeResults, map[string]interface{}{
				"id":          id,
				"title":       title,
				"intro_start": introStart,
				"intro_end":   introEnd,
				"outro_start": outroStart,
				"outro_end":   outroEnd,
				"has_intro":   introStart > 0 && introEnd > 0,
				"has_outro":   outroStart > 0 && outroEnd > 0,
			})
		}
		epRows.Close()

		results = append(results, map[string]interface{}{
			"season_id":    season.ID,
			"season_title": season.Title,
			"episodes":     episodeResults,
		})
	}

	log.Printf("Detection: Show %d scan complete. Processed %d seasons.", showID, len(seasons))
	return results, nil
}

type EpisodeInfo struct {
	ID       int
	Title    string
	FilePath string
	Duration int
	Season   int
	Episode  int
}

func AnalyzeSeason(seasonID int) error {
	var seasonNumber int
	var showID int
	err := database.DB.QueryRow(`
		SELECT COALESCE(NULLIF(season_number, 0), 0), parent_id
		FROM medias
		WHERE id = ? AND type = 'season'
	`, seasonID).Scan(&seasonNumber, &showID)
	if err != nil {
		return fmt.Errorf("failed to get season number or show ID: %v", err)
	}
	if seasonNumber <= 0 {
		var seasonTitle string
		if err := database.DB.QueryRow("SELECT title FROM medias WHERE id = ?", seasonID).Scan(&seasonTitle); err == nil {
			seasonNumber = parseSeasonNumberFromTitle(seasonTitle)
		}
	}

	// Get the show's TMDB ID (tmdb_id is stored on the show, not the season)
	var showTMDBID sql.NullInt64
	_ = database.DB.QueryRow("SELECT tmdb_id FROM medias WHERE id = ? AND type = 'show'", showID).Scan(&showTMDBID)

	// Check if we already have a cached imdb_id for this show
	var imdbID string
	_ = database.DB.QueryRow("SELECT imdb_id FROM medias WHERE id = ? AND type = 'show'", showID).Scan(&imdbID)

	// If not cached, try to convert TMDB ID to IMDb ID
	if imdbID == "" && showTMDBID.Valid {
		imdbID, err = GetIMDbIDFromTMDB(int(showTMDBID.Int64))
		if err != nil {
			log.Printf("Detection: Failed to get IMDb ID for TMDB ID %d: %v (will fallback to chapters)", showTMDBID.Int64, err)
			// Continue with chapter detection as fallback
			imdbID = ""
		} else {
			// Cache the IMDb ID for future use
			_, _ = database.DB.Exec("UPDATE medias SET imdb_id = ? WHERE id = ? AND type = 'show'", imdbID, showID)
			log.Printf("Detection: Cached IMDb ID %s for show ID %d", imdbID, showID)
		}
	} else if imdbID == "" {
		log.Printf("Detection: Season %d has no TMDB ID, will use chapter detection only", seasonID)
	} else {
		log.Printf("Detection: Using cached IMDb ID %s for show ID %d", imdbID, showID)
	}

	// Fetch all episodes in this season with their episode numbers
	rows, err := database.DB.Query(`
		SELECT id, title, file_path, duration, COALESCE(episode_number, 0)
		FROM medias
		WHERE type = 'episode' AND parent_id = ?
		ORDER BY COALESCE(NULLIF(episode_number, 0), 9999), id ASC
	`, seasonID)
	if err != nil {
		return err
	}
	defer rows.Close()

	var episodes []EpisodeInfo
	for rows.Next() {
		var ep EpisodeInfo
		var filePath sql.NullString
		var epNum int
		if err := rows.Scan(&ep.ID, &ep.Title, &filePath, &ep.Duration, &epNum); err == nil {
			if filePath.Valid && filePath.String != "" {
				ep.FilePath = filePath.String
				ep.Episode = epNum
				if ep.Episode <= 0 {
					if s, e, ok := ParseEpisodeNumbers(filepath.Base(ep.FilePath)); ok && s == seasonNumber {
						ep.Episode = e
					} else if s, e, ok := ParseEpisodeNumbers(ep.Title); ok && s == seasonNumber {
						ep.Episode = e
					}
				}
				ep.Season = seasonNumber
				episodes = append(episodes, ep)
			}
		}
	}
	rows.Close()

	if len(episodes) == 0 {
		return nil
	}

	// Try TheIntroDB first if we have an IMDb ID
	if imdbID != "" {
		log.Printf("Detection: Using TheIntroDB for show %s (IMDb ID: %s)", imdbID, imdbID)
		
		for _, ep := range episodes {
			if ep.Episode == 0 {
				log.Printf("Detection: Skipping episode %d (no episode number)", ep.ID)
				continue
			}

			segments, err := FetchSegmentsFromIntroDB(imdbID, ep.Season, ep.Episode)
			if err != nil {
				log.Printf("Detection: Failed to fetch segments for S%dE%d: %v", ep.Season, ep.Episode, err)
				continue
			}

			if segments == nil {
				log.Printf("Detection: No data found in IntroDB for S%dE%d", ep.Season, ep.Episode)
				continue
			}

			introStart, introEnd, outroStart, outroEnd := 0, 0, 0, 0

			if skipStart, skipEnd, ok := MergeIntroDBSkipRange(segments.Intro, segments.Recap); ok {
				if IsPlausibleIntroRange(skipStart, skipEnd, 0) {
					introStart = skipStart
					introEnd = skipEnd
					log.Printf("Detection: IntroDB skip window for S%dE%d: [%d-%ds]",
						ep.Season, ep.Episode, introStart, introEnd)
				}
			}

			// Use outro from IntroDB
			if segments.Outro != nil {
				outroStart = int(segments.Outro.StartSec)
				outroEnd = int(segments.Outro.EndSec)
				log.Printf("Detection: IntroDB found outro for S%dE%d: [%d-%ds] (confidence: %.2f)",
					ep.Season, ep.Episode, outroStart, outroEnd, segments.Outro.Confidence)
			}

			// Update database
			_, err = database.DB.Exec(
				"UPDATE medias SET intro_start = ?, intro_end = ?, outro_start = ?, outro_end = ? WHERE id = ?",
				introStart, introEnd, outroStart, outroEnd, ep.ID,
			)
			if err != nil {
				log.Printf("Detection: Failed to save timestamps for episode %d: %v", ep.ID, err)
			}
		}
	}

	// Fallback: Try chapters for episodes that still don't have intro/outro
	for _, ep := range episodes {
		var currentIntroStart, currentOutroStart int
		_ = database.DB.QueryRow("SELECT intro_start, outro_start FROM medias WHERE id = ?", ep.ID).Scan(&currentIntroStart, &currentOutroStart)
		
		// Skip if we already have both intro and outro from IntroDB
		if currentIntroStart > 0 && currentOutroStart > 0 {
			continue
		}

		found, err := DetectFromChapters(ep.ID, ep.FilePath)
		if err == nil && found {
			log.Printf("Detection: Episode %d successfully mapped using FFprobe chapters as fallback.", ep.ID)
		}
	}

	return nil
}

// min helper
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// max helper
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
