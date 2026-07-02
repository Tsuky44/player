package handlers

import (
	"database/sql"
	"log"
	"sort"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

// resolveShowFromEpisode returns show id/title/poster for an episode row.
// Handles the normal Show → Season → Episode tree and a direct Episode → Show link.
func resolveShowFromEpisode(episodeID, episodeParentID int) (showID int, showTitle, showPoster string, ok bool) {
	_ = episodeID
	// Standard: episode.parent_id → season → show
	err := database.DB.QueryRow(`
		SELECT show_m.id, show_m.title, COALESCE(show_m.poster_url, '')
		FROM medias season
		JOIN medias show_m ON show_m.id = season.parent_id AND show_m.type = 'show'
		WHERE season.id = ? AND season.type = 'season'
		LIMIT 1`, episodeParentID,
	).Scan(&showID, &showTitle, &showPoster)
	if err == nil && showID > 0 {
		return showID, showTitle, showPoster, true
	}

	// Fallback: episode linked directly to a show (legacy / bad index data).
	err = database.DB.QueryRow(`
		SELECT id, title, COALESCE(poster_url, '')
		FROM medias
		WHERE id = ? AND type = 'show'
		LIMIT 1`, episodeParentID,
	).Scan(&showID, &showTitle, &showPoster)
	if err == nil && showID > 0 {
		return showID, showTitle, showPoster, true
	}

	return 0, "", "", false
}

func scanContinueWatchingMovieRow(rows *sql.Rows) (models.HomeMediaItem, time.Time, error) {
	var item models.HomeMediaItem
	var parentID sql.NullInt64
	var filePath, posterURL, overview, releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var updatedAt time.Time
	var isFinishedInt int

	err := rows.Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL,
		&overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &isFinishedInt,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&updatedAt,
	)
	if err != nil {
		return item, time.Time{}, err
	}

	if filePath.Valid {
		item.FilePath = filePath.String
	}
	if parentID.Valid {
		pid := int(parentID.Int64)
		item.ParentID = &pid
	}
	if posterURL.Valid {
		item.PosterURL = posterURL.String
	}
	if overview.Valid {
		item.Overview = overview.String
	}
	if releaseDate.Valid {
		item.ReleaseDate = releaseDate.String
	}
	if tmdbID.Valid {
		item.TMDBID = int(tmdbID.Int64)
	}
	item.IsFinished = isFinishedInt != 0
	item.UpdatedAt = updatedAt
	return item, updatedAt, nil
}

type continueWatchingEpisodeRow struct {
	item   models.HomeMediaItem
	showID int
}

func scanContinueWatchingEpisodeRow(rows *sql.Rows) (continueWatchingEpisodeRow, error) {
	var out continueWatchingEpisodeRow
	var item models.HomeMediaItem
	var filePath, posterURL, overview, releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var parentID int
	var seasonNumber, episodeNumber int
	var isFinishedInt int
	var updatedAt time.Time
	var showTitle, showPoster sql.NullString
	var seasonTitle string

	err := rows.Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL,
		&overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &isFinishedInt,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&seasonNumber, &episodeNumber, &seasonTitle,
		&out.showID, &showTitle, &showPoster,
		&updatedAt,
	)
	if err != nil {
		return out, err
	}

	if filePath.Valid {
		item.FilePath = filePath.String
	}
	item.ParentID = &parentID
	if posterURL.Valid {
		item.PosterURL = posterURL.String
	}
	if overview.Valid {
		item.Overview = overview.String
	}
	if releaseDate.Valid {
		item.ReleaseDate = releaseDate.String
	}
	if tmdbID.Valid {
		item.TMDBID = int(tmdbID.Int64)
	}
	item.SeasonNumber = resolveSeasonNumber(seasonTitle, item.FilePath, seasonNumber)
	item.EpisodeNumber = episodeNumber
	item.IsFinished = isFinishedInt != 0
	item.UpdatedAt = updatedAt
	if showTitle.Valid {
		item.ShowTitle = showTitle.String
	}
	if showPoster.Valid {
		item.ShowPosterURL = showPoster.String
	}
	item.ShowID = out.showID
	item.EpisodeTitle = item.Title

	out.item = item
	return out, nil
}

func buildMovieContinueWatching(userID int) ([]models.HomeMediaItem, error) {
	rows, err := database.DB.Query(`
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url,
		       m.overview, m.release_date, m.tmdb_id, m.created_at,
		       p.current_position_seconds, p.is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end,
		       p.updated_at
		FROM progressions p
		JOIN medias m ON p.media_id = m.id AND m.type = 'movie'
		WHERE p.user_id = ?
		  AND IFNULL(p.is_finished, 0) = 0
		  AND p.current_position_seconds > 0
		ORDER BY p.updated_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []models.HomeMediaItem
	for rows.Next() {
		item, _, err := scanContinueWatchingMovieRow(rows)
		if err != nil {
			log.Printf("ContinueWatching: movie scan error: %v", err)
			continue
		}
		items = append(items, item)
	}
	return items, nil
}

func buildShowContinueWatching(userID int) ([]models.HomeMediaItem, error) {
	// Resolve show metadata in SQL — never nest DB calls while rows are open
	// (SQLite uses one connection; open cursor + QueryRow deadlocks forever).
	rows, err := database.DB.Query(`
		SELECT ep.id, ep.type, ep.title, ep.file_path, ep.duration, ep.parent_id,
		       COALESCE(NULLIF(ep.poster_url, ''), COALESCE(show_s.poster_url, show_d.poster_url, ''), '') AS poster_url,
		       ep.overview, ep.release_date, ep.tmdb_id, ep.created_at,
		       p.current_position_seconds, p.is_finished,
		       ep.intro_start, ep.intro_end, ep.outro_start, ep.outro_end,
		       COALESCE(season.season_number, ep.season_number, 0),
		       COALESCE(ep.episode_number, 0),
		       COALESCE(season.title, ''),
		       COALESCE(show_s.id, show_d.id) AS show_id,
		       COALESCE(show_s.title, show_d.title, '') AS show_title,
		       COALESCE(show_s.poster_url, show_d.poster_url, '') AS show_poster,
		       p.updated_at
		FROM progressions p
		JOIN medias ep ON p.media_id = ep.id AND ep.type = 'episode'
		LEFT JOIN medias season ON season.id = ep.parent_id AND season.type = 'season'
		LEFT JOIN medias show_s ON show_s.id = season.parent_id AND show_s.type = 'show'
		LEFT JOIN medias show_d ON show_d.id = ep.parent_id AND show_d.type = 'show'
		WHERE p.user_id = ?
		  AND IFNULL(p.is_finished, 0) = 0
		  AND p.current_position_seconds > 0
		  AND COALESCE(show_s.id, show_d.id) IS NOT NULL
		ORDER BY p.updated_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	seenShows := make(map[int]bool)
	var items []models.HomeMediaItem

	for rows.Next() {
		row, err := scanContinueWatchingEpisodeRow(rows)
		if err != nil {
			log.Printf("ContinueWatching: episode scan error: %v", err)
			continue
		}
		if row.showID <= 0 || seenShows[row.showID] {
			continue
		}
		seenShows[row.showID] = true
		items = append(items, row.item)
	}

	log.Printf("ContinueWatching: %d in-progress show(s) for user %d", len(items), userID)
	return items, nil
}

func buildContinueWatching(userID int, limit int) ([]models.HomeMediaItem, error) {
	movies, err := buildMovieContinueWatching(userID)
	if err != nil {
		return nil, err
	}

	shows, err := buildShowContinueWatching(userID)
	if err != nil {
		log.Printf("ContinueWatching: show query failed for user %d: %v", userID, err)
		shows = nil
	}

	combined := append(movies, shows...)
	sort.Slice(combined, func(i, j int) bool {
		return combined[i].UpdatedAt.After(combined[j].UpdatedAt)
	})

	if limit > 0 && len(combined) > limit {
		combined = combined[:limit]
	}
	return combined, nil
}
