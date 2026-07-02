package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"project-player/server/database"
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

func loadShowEpisodesWithProgress(showID, userID int) ([]episodeProgressRow, error) {
	query := `
		SELECT ep.id, ep.type, ep.title, ep.file_path, ep.duration, ep.parent_id,
		       COALESCE(NULLIF(ep.poster_url, ''), show_m.poster_url, '') AS poster_url,
		       ep.overview, ep.release_date, ep.tmdb_id, ep.created_at,
		       COALESCE(p.current_position_seconds, 0), COALESCE(p.is_finished, 0),
		       ep.intro_start, ep.intro_end, ep.outro_start, ep.outro_end,
		       season.id, COALESCE(season.season_number, 0), COALESCE(ep.episode_number, 0),
		       season.title, COALESCE(p.updated_at, ep.created_at) AS last_activity
		FROM medias ep
		JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
		JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = ep.id AND p.user_id = ?
		WHERE show_m.id = ? AND ep.type = 'episode'
		ORDER BY
		  CASE WHEN COALESCE(season.season_number, 0) = 0 THEN 9999 ELSE season.season_number END,
		  CASE WHEN COALESCE(ep.episode_number, 0) = 0 THEN 9999 ELSE ep.episode_number END,
		  ep.id ASC
	`
	rows, err := database.DB.Query(query, userID, showID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []episodeProgressRow
	for rows.Next() {
		var row episodeProgressRow
		var filePath, posterURL, overview, releaseDate sql.NullString
		var tmdbID sql.NullInt64
		var parentID int
		var seasonTitle string
		var isFinishedInt int
		var storedSeason, storedEpisode int
		var lastActivity sql.NullString

		err := rows.Scan(
			&row.item.ID, &row.item.Type, &row.item.Title, &filePath, &row.item.Duration, &parentID,
			&posterURL, &overview, &releaseDate, &tmdbID, &row.item.CreatedAt,
			&row.currentPosition, &isFinishedInt,
			&row.item.IntroStart, &row.item.IntroEnd, &row.item.OutroStart, &row.item.OutroEnd,
			&row.seasonID, &storedSeason, &storedEpisode, &seasonTitle, &lastActivity,
		)
		if err != nil {
			log.Printf("Resume: scan error: %v", err)
			continue
		}

		row.item.ParentID = &parentID
		if filePath.Valid {
			row.item.FilePath = filePath.String
		}
		if posterURL.Valid {
			row.item.PosterURL = posterURL.String
		}
		if overview.Valid {
			row.item.Overview = overview.String
		}
		if releaseDate.Valid {
			row.item.ReleaseDate = releaseDate.String
		}
		if tmdbID.Valid {
			row.item.TMDBID = int(tmdbID.Int64)
		}
		fp := ""
		if filePath.Valid {
			fp = filePath.String
		}
		row.seasonNumber = resolveSeasonNumber(seasonTitle, fp, storedSeason)
		row.episodeNumber = parseEpisodeNumber(row.item.Title, storedEpisode)
		row.isFinished = isFinishedInt != 0
		row.lastUpdated = scanSQLiteTime(lastActivity)
		row.item.CurrentPositionSeconds = row.currentPosition
		row.item.IsFinished = row.isFinished

		out = append(out, row)
	}
	return out, nil
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
