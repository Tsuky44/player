package indexer

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/models"
)

var (
	seasonTitleNumRe      = regexp.MustCompile(`(?i)^\s*saison\s*(\d+)\s*$`)
	episodeFilenameLikeRe = regexp.MustCompile(`(?i)(webdl|webrip|web-dl|1080p|720p|2160p|x264|x265|hdtv|bluray|\.mkv|\.mp4)`)
	seasonEpisodeRefresh  sync.Map // seasonID -> time.Time
)

type tmdbEpisodeDetails struct {
	ID            int    `json:"id"`
	Name          string `json:"name"`
	Overview      string `json:"overview"`
	StillPath     string `json:"still_path"`
	AirDate       string `json:"air_date"`
	EpisodeNumber int    `json:"episode_number"`
}

type tmdbEpisodeTranslationsResponse struct {
	Translations []struct {
		ISO6391 string `json:"iso_639_1"`
		Data    struct {
			Name     string `json:"name"`
			Overview string `json:"overview"`
		} `json:"data"`
	} `json:"translations"`
}

// EpisodeNeedsTMDBRefresh reports whether a stored title still looks like a release filename.
func EpisodeNeedsTMDBRefresh(title string) bool {
	title = strings.TrimSpace(title)
	if title == "" {
		return true
	}
	if episodeFilenameLikeRe.MatchString(title) {
		return true
	}
	if episodeRegex.MatchString(title) && strings.Contains(title, " - ") {
		return true
	}
	return false
}

func parseSeasonNumberFromTitle(title string) int {
	m := seasonTitleNumRe.FindStringSubmatch(strings.TrimSpace(title))
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func stillURLFromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/w500" + path
}

func fetchTMDBEpisodeTranslation(showTMDBID, seasonNum, episodeNum int) (title, overview string) {
	apiKey := tmdbAPIKey()
	if apiKey == "" {
		return "", ""
	}
	u := fmt.Sprintf(
		"https://api.themoviedb.org/3/tv/%d/season/%d/episode/%d/translations?api_key=%s",
		showTMDBID, seasonNum, episodeNum, apiKey,
	)
	resp, err := httpx.Standard.Get(u)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return "", ""
	}
	defer resp.Body.Close()

	var out tmdbEpisodeTranslationsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", ""
	}
	wantLang := tmdbTranslationISO639()
	for _, tr := range out.Translations {
		if strings.EqualFold(tr.ISO6391, wantLang) {
			return strings.TrimSpace(tr.Data.Name), strings.TrimSpace(tr.Data.Overview)
		}
	}
	return "", ""
}

func fetchTMDBEpisode(showTMDBID, seasonNum, episodeNum int) (title, overview, posterURL, airDate string, episodeTMDBID int) {
	apiKey := tmdbAPIKey()
	if apiKey == "" || showTMDBID <= 0 || seasonNum <= 0 || episodeNum <= 0 {
		return "", "", "", "", 0
	}

	fetch := func(lang string) tmdbEpisodeDetails {
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/tv/%d/season/%d/episode/%d?api_key=%s",
			showTMDBID, seasonNum, episodeNum, apiKey,
		)
		if lang != "" {
			u += "&language=" + lang
		}
		resp, err := httpx.Standard.Get(u)
		if err != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			return tmdbEpisodeDetails{}
		}
		defer resp.Body.Close()
		var d tmdbEpisodeDetails
		_ = json.NewDecoder(resp.Body).Decode(&d)
		return d
	}

	loc := fetch(tmdbLanguage())
	fallback := tmdbEpisodeDetails{}
	if loc.StillPath == "" || loc.Overview == "" || loc.Name == "" {
		fallback = fetch("")
	}

	title = strings.TrimSpace(loc.Name)
	if title == "" {
		title = strings.TrimSpace(fallback.Name)
	}
	fallbackTitle := strings.TrimSpace(fallback.Name)
	if title == "" || (fallbackTitle != "" && strings.EqualFold(title, fallbackTitle)) {
		if trTitle, trOverview := fetchTMDBEpisodeTranslation(showTMDBID, seasonNum, episodeNum); trTitle != "" {
			title = trTitle
			if trOverview != "" {
				loc.Overview = trOverview
			}
		}
	}
	overview = strings.TrimSpace(loc.Overview)
	if overview == "" {
		overview = strings.TrimSpace(fallback.Overview)
	}
	stillPath := loc.StillPath
	if stillPath == "" {
		stillPath = fallback.StillPath
	}
	posterURL = stillURLFromPath(stillPath)

	airDate = loc.AirDate
	if airDate == "" {
		airDate = fallback.AirDate
	}

	episodeTMDBID = loc.ID
	if episodeTMDBID == 0 {
		episodeTMDBID = fallback.ID
	}
	return title, overview, posterURL, airDate, episodeTMDBID
}

func fallbackEpisodeTitle(seasonNum, episodeNum int) string {
	return fmt.Sprintf("Épisode %d", episodeNum)
}

func resolveEpisodeNumbers(filePath, episodeTitle, seasonTitle string, storedSeason, storedEpisode int) (seasonNum, episodeNum int) {
	if storedSeason > 0 {
		seasonNum = storedSeason
	} else {
		seasonNum = parseSeasonNumberFromTitle(seasonTitle)
	}
	if storedEpisode > 0 {
		episodeNum = storedEpisode
	}
	if episodeNum == 0 && filePath != "" {
		base := filepath.Base(filePath)
		if s, e, ok := ParseEpisodeNumbers(base); ok {
			if seasonNum == 0 {
				seasonNum = s
			}
			episodeNum = e
		}
	}
	if episodeNum == 0 && episodeTitle != "" {
		if s, e, ok := ParseEpisodeNumbers(episodeTitle); ok {
			if seasonNum == 0 {
				seasonNum = s
			}
			episodeNum = e
		}
	}
	return seasonNum, episodeNum
}

func enrichEpisodeFromTMDB(episodeID, showTMDBID, seasonNum, episodeNum int) bool {
	title, overview, posterURL, airDate, episodeTMDBID := fetchTMDBEpisode(showTMDBID, seasonNum, episodeNum)
	if title == "" && overview == "" && posterURL == "" {
		return false
	}
	if title == "" {
		title = fallbackEpisodeTitle(seasonNum, episodeNum)
	}

	_, err := database.DB.Exec(`
		UPDATE medias SET
			title = ?,
			overview = CASE WHEN ? != '' THEN ? ELSE overview END,
			poster_url = CASE WHEN ? != '' THEN ? ELSE poster_url END,
			release_date = CASE WHEN ? != '' AND (release_date IS NULL OR release_date = '') THEN ? ELSE release_date END,
			tmdb_id = CASE WHEN ? > 0 AND (tmdb_id IS NULL OR tmdb_id = 0) THEN ? ELSE tmdb_id END,
			season_number = CASE WHEN season_number IS NULL OR season_number = 0 THEN ? ELSE season_number END,
			episode_number = CASE WHEN episode_number IS NULL OR episode_number = 0 THEN ? ELSE episode_number END
		WHERE id = ? AND type = 'episode'`,
		title,
		overview, overview,
		posterURL, posterURL,
		airDate, airDate,
		episodeTMDBID, episodeTMDBID,
		seasonNum, episodeNum,
		episodeID,
	)
	if err != nil {
		log.Printf("TMDB: failed to enrich episode %d: %v", episodeID, err)
		return false
	}
	log.Printf("TMDB: enriched episode S%02dE%02d %q (id=%d)", seasonNum, episodeNum, title, episodeID)
	return true
}

func ensureShowHasTMDBID(showID int) {
	if tmdbAPIKey() == "" {
		return
	}
	var title string
	var tmdbID sql.NullInt64
	err := database.DB.QueryRow(
		"SELECT title, tmdb_id FROM medias WHERE id = ? AND type = 'show'", showID,
	).Scan(&title, &tmdbID)
	if err != nil {
		return
	}
	if tmdbID.Valid && tmdbID.Int64 > 0 {
		return
	}
	enrichMediaRecord(showID, enrichSearchTitle(title, "", models.TypeShow, showID), models.TypeShow, 0)
}

// RefreshSeasonEpisodesFromTMDB updates episode titles from TMDB when they still look like filenames.
func RefreshSeasonEpisodesFromTMDB(seasonID int) {
	if tmdbAPIKey() == "" || seasonID <= 0 {
		return
	}

	var showID int
	var showTMDBID int
	var seasonTitle string
	err := database.DB.QueryRow(`
		SELECT season.parent_id, COALESCE(show_m.tmdb_id, 0), season.title
		FROM medias season
		JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		WHERE season.id = ? AND season.type = 'season'`, seasonID,
	).Scan(&showID, &showTMDBID, &seasonTitle)
	if err != nil {
		return
	}
	if showTMDBID == 0 {
		ensureShowHasTMDBID(showID)
		showTMDBID = lookupShowTMDBID(showID)
	}
	if showTMDBID == 0 {
		return
	}

	rows, err := database.DB.Query(`
		SELECT id, title, COALESCE(file_path, ''), COALESCE(season_number, 0), COALESCE(episode_number, 0)
		FROM medias
		WHERE type = 'episode' AND parent_id = ?
		ORDER BY COALESCE(NULLIF(episode_number, 0), 9999), id ASC`, seasonID)
	if err != nil {
		return
	}
	defer rows.Close()

	type epRow struct {
		id         int
		title      string
		filePath   string
		seasonNum  int
		episodeNum int
	}
	var episodes []epRow
	needsRefresh := false
	for rows.Next() {
		var ep epRow
		if err := rows.Scan(&ep.id, &ep.title, &ep.filePath, &ep.seasonNum, &ep.episodeNum); err != nil {
			continue
		}
		if EpisodeNeedsTMDBRefresh(ep.title) {
			needsRefresh = true
		}
		episodes = append(episodes, ep)
	}
	if !needsRefresh || len(episodes) == 0 {
		return
	}
	if last, ok := seasonEpisodeRefresh.Load(seasonID); ok {
		if time.Since(last.(time.Time)) < 2*time.Minute {
			return
		}
	}

	log.Printf("TMDB: refreshing episode titles for season %d (show tmdb=%d)", seasonID, showTMDBID)
	for _, ep := range episodes {
		if !EpisodeNeedsTMDBRefresh(ep.title) {
			continue
		}
		seasonNum, episodeNum := resolveEpisodeNumbers(ep.filePath, ep.title, seasonTitle, ep.seasonNum, ep.episodeNum)
		if seasonNum == 0 || episodeNum == 0 {
			log.Printf("TMDB: skip episode %d — could not resolve S/E (title=%q)", ep.id, ep.title)
			continue
		}
		enrichEpisodeFromTMDB(ep.id, showTMDBID, seasonNum, episodeNum)
		time.Sleep(120 * time.Millisecond)
	}
	seasonEpisodeRefresh.Store(seasonID, time.Now())
}

func backfillEpisodeMetadata() {
	if tmdbAPIKey() == "" {
		return
	}

	rows, err := database.DB.Query(`
		SELECT ep.id, ep.title, COALESCE(ep.file_path, ''), COALESCE(ep.season_number, 0), COALESCE(ep.episode_number, 0),
		       season.title, COALESCE(show_m.tmdb_id, 0),
		       (COALESCE(ep.tmdb_id, 0) = 0 OR COALESCE(ep.poster_url, '') = ''
		        OR COALESCE(ep.overview, '') = '' OR COALESCE(ep.release_date, '') = '')
		FROM medias ep
		JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
		JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		WHERE ep.type = 'episode'
		  AND show_m.tmdb_id IS NOT NULL AND show_m.tmdb_id > 0
		ORDER BY show_m.id, season.title, ep.id`)
	if err != nil {
		log.Printf("TMDB: episode metadata backfill query failed: %v", err)
		return
	}
	defer rows.Close()

	type item struct {
		id          int
		title       string
		filePath    string
		seasonNum   int
		episodeNum  int
		seasonTitle string
		showTMDBID  int
	}
	var queue []item
	for rows.Next() {
		var it item
		var missing bool
		if err := rows.Scan(&it.id, &it.title, &it.filePath, &it.seasonNum, &it.episodeNum, &it.seasonTitle, &it.showTMDBID, &missing); err != nil {
			continue
		}
		if missing || EpisodeNeedsTMDBRefresh(it.title) {
			queue = append(queue, it)
		}
	}

	if len(queue) == 0 {
		return
	}

	log.Printf("TMDB: enriching %d episodes from TMDB (%s)…", len(queue), tmdbLanguage())
	updated := 0
	for i, it := range queue {
		seasonNum, episodeNum := resolveEpisodeNumbers(it.filePath, it.title, it.seasonTitle, it.seasonNum, it.episodeNum)
		if seasonNum == 0 || episodeNum == 0 {
			continue
		}
		if enrichEpisodeFromTMDB(it.id, it.showTMDBID, seasonNum, episodeNum) {
			updated++
		}
		if (i+1)%25 == 0 || i+1 == len(queue) {
			log.Printf("TMDB: episode metadata progress %d/%d", i+1, len(queue))
		}
		time.Sleep(260 * time.Millisecond)
	}
	log.Printf("TMDB: episode metadata backfill done (%d updated)", updated)
}

func lookupShowTMDBID(showID int) int {
	var tmdbID sql.NullInt64
	_ = database.DB.QueryRow("SELECT tmdb_id FROM medias WHERE id = ? AND type = 'show'", showID).Scan(&tmdbID)
	if tmdbID.Valid {
		return int(tmdbID.Int64)
	}
	return 0
}
