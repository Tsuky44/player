package handlers

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
	"time"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

var seasonTitleNumRe = regexp.MustCompile(`(?i)(?:saison|season)\s*(\d+)`)
var episodeNumInTitleRe = regexp.MustCompile(`(?i)s(\d+)e(\d+)`)

type episodeProgressRow struct {
	item            models.HomeMediaItem
	seasonID        int
	seasonNumber    int
	episodeNumber   int
	isFinished      bool
	currentPosition int
	lastUpdated     time.Time
}

func parseSeasonNumber(title string, stored int) int {
	if stored > 0 {
		return stored
	}
	m := seasonTitleNumRe.FindStringSubmatch(strings.TrimSpace(title))
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func resolveSeasonNumber(seasonTitle, filePath string, stored int) int {
	if n := parseSeasonNumber(seasonTitle, stored); n > 0 {
		return n
	}
	if filePath == "" {
		return 0
	}
	m := episodeNumInTitleRe.FindStringSubmatch(filepath.Base(filePath))
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func parseEpisodeNumber(title string, stored int) int {
	if stored > 0 {
		return stored
	}
	m := episodeNumInTitleRe.FindStringSubmatch(title)
	if len(m) < 3 {
		return 0
	}
	n, _ := strconv.Atoi(m[2])
	return n
}

// episodeProgressQuery loads every episode of one or more shows with the
// caller's progression attached. The %s is the IN list of show ids.
//
// COALESCE does the null-handling in SQL rather than in Go: every column below
// is scanned into a plain string or int, which is why this function has no
// sql.Null* plumbing.
const episodeProgressQuery = `
	SELECT show_m.id,
	       ep.id, ep.type, ep.title, COALESCE(ep.file_path, ''), ep.duration, ep.parent_id,
	       COALESCE(NULLIF(ep.poster_url, ''), show_m.poster_url, '') AS poster_url,
	       COALESCE(ep.overview, ''), COALESCE(ep.release_date, ''), COALESCE(ep.tmdb_id, 0),
	       ep.created_at,
	       COALESCE(p.current_position_seconds, 0), COALESCE(p.is_finished, 0),
	       ep.intro_start, ep.intro_end, ep.outro_start, ep.outro_end,
	       season.id, COALESCE(season.season_number, 0), COALESCE(ep.episode_number, 0),
	       season.title, COALESCE(p.updated_at, ep.created_at) AS last_activity
	FROM medias ep
	JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
	JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
	LEFT JOIN progressions p ON p.media_id = ep.id AND p.user_id = ?
	WHERE show_m.id IN (%s) AND ep.type = 'episode'
	ORDER BY
	  show_m.id,
	  CASE WHEN COALESCE(season.season_number, 0) = 0 THEN 9999 ELSE season.season_number END,
	  CASE WHEN COALESCE(ep.episode_number, 0) = 0 THEN 9999 ELSE ep.episode_number END,
	  ep.id ASC
`

// loadEpisodesWithProgressForShows loads the episodes of several shows at once.
//
// The home screen needs this for every show the user has started, and doing it
// one show at a time cost a round trip per show — the single most expensive
// thing on /api/home for anyone following more than a couple of series.
func loadEpisodesWithProgressForShows(userID int, showIDs []int) (map[int][]episodeProgressRow, error) {
	byShow := make(map[int][]episodeProgressRow, len(showIDs))
	if len(showIDs) == 0 {
		return byShow, nil
	}

	args := make([]interface{}, 0, len(showIDs)+1)
	args = append(args, userID)
	for _, id := range showIDs {
		args = append(args, id)
	}

	rows, err := database.DB.Query(
		fmt.Sprintf(episodeProgressQuery, sqlPlaceholders(len(showIDs))), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		showID, row, err := scanEpisodeProgressRow(rows)
		if err != nil {
			log.Printf("Resume: scan error: %v", err)
			continue
		}
		byShow[showID] = append(byShow[showID], row)
	}
	return byShow, rows.Err()
}

func scanEpisodeProgressRow(rows *sql.Rows) (showID int, row episodeProgressRow, err error) {
	var parentID int
	var seasonTitle string
	var isFinishedInt int
	var storedSeason, storedEpisode int
	var lastActivity sql.NullString

	err = rows.Scan(
		&showID,
		&row.item.ID, &row.item.Type, &row.item.Title, &row.item.FilePath, &row.item.Duration, &parentID,
		&row.item.PosterURL, &row.item.Overview, &row.item.ReleaseDate, &row.item.TMDBID,
		&row.item.CreatedAt,
		&row.currentPosition, &isFinishedInt,
		&row.item.IntroStart, &row.item.IntroEnd, &row.item.OutroStart, &row.item.OutroEnd,
		&row.seasonID, &storedSeason, &storedEpisode, &seasonTitle, &lastActivity,
	)
	if err != nil {
		return 0, episodeProgressRow{}, err
	}

	row.item.ParentID = &parentID
	row.seasonNumber = resolveSeasonNumber(seasonTitle, row.item.FilePath, storedSeason)
	row.episodeNumber = parseEpisodeNumber(row.item.Title, storedEpisode)
	row.isFinished = isFinishedInt != 0
	row.lastUpdated = scanSQLiteTime(lastActivity)
	row.item.CurrentPositionSeconds = row.currentPosition
	row.item.IsFinished = row.isFinished

	return showID, row, nil
}

func loadShowEpisodesWithProgress(showID, userID int) ([]episodeProgressRow, error) {
	byShow, err := loadEpisodesWithProgressForShows(userID, []int{showID})
	if err != nil {
		return nil, err
	}
	return byShow[showID], nil
}

func findResumeEpisodeRow(episodes []episodeProgressRow) (*episodeProgressRow, bool) {
	if len(episodes) == 0 {
		return nil, false
	}

	for i := range episodes {
		ep := &episodes[i]
		if ep.currentPosition > 0 && !ep.isFinished {
			return ep, true
		}
	}

	lastFinishedIdx := -1
	for i := range episodes {
		if episodes[i].isFinished {
			lastFinishedIdx = i
		}
	}
	if lastFinishedIdx >= 0 && lastFinishedIdx+1 < len(episodes) {
		next := &episodes[lastFinishedIdx+1]
		next.item.CurrentPositionSeconds = 0
		next.item.IsFinished = false
		return next, true
	}
	if lastFinishedIdx >= 0 && lastFinishedIdx == len(episodes)-1 {
		return nil, false
	}

	for i := range episodes {
		ep := &episodes[i]
		if !ep.isFinished && ep.currentPosition == 0 {
			return ep, true
		}
	}

	first := &episodes[0]
	first.item.CurrentPositionSeconds = 0
	first.item.IsFinished = false
	return first, true
}

// GetShowResumeEpisode returns the episode to resume for a TV show (GET /api/shows/:id/resume).
func GetShowResumeEpisode(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	showID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}
	showID = indexer.ResolveCanonicalShowID(showID)

	episodes, err := loadShowEpisodesWithProgress(showID, userID)
	if err != nil {
		log.Printf("Resume: query failed for show %d: %v", showID, err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	row, ok := findResumeEpisodeRow(episodes)
	if !ok || row == nil {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"has_episode": false,
		})
		return
	}

	row.item.SeasonNumber = row.seasonNumber
	row.item.EpisodeNumber = row.episodeNumber

	json.NewEncoder(w).Encode(map[string]interface{}{
		"has_episode": true,
		"season_id":   row.seasonID,
		"episode":     row.item,
	})
}
