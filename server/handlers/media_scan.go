package handlers

import (
	"database/sql"
	"log"
	"strings"

	"project-player/server/database"
	"project-player/server/models"
)

// Row projections and scanners for the medias table.
//
// Every library endpoint used to carry its own copy of the same twenty-five
// lines: declare a sql.NullString per nullable column, scan, then unwrap each
// one with `if x.Valid { … }`. The same block appeared six times in media.go
// alone, which meant adding a column to medias was a ten-file edit with no
// compiler help if you missed one.
//
// Two things fix that. The projections below are shared constants, so the
// column list lives in one place; and they COALESCE in SQL, so every value
// arrives as a plain string or int and the sql.Null* unwrapping disappears
// entirely. The pattern is not new here — loadLocalSeasons already did it — it
// is just applied everywhere now.
//
// All projections alias the medias table as `m`; the ones carrying progression
// need `LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?`.

// mediaColumns projects a plain models.Media.
const mediaColumns = `m.id, m.type, m.title, COALESCE(m.file_path, ''), COALESCE(m.duration, 0),
	COALESCE(m.parent_id, 0), COALESCE(m.poster_url, ''), COALESCE(m.overview, ''),
	COALESCE(m.release_date, ''), COALESCE(m.tmdb_id, 0), COALESCE(m.imdb_id, ''), m.created_at`

// libraryItemColumns adds intro/outro markers and the caller's progression,
// producing a models.HomeMediaItem.
const libraryItemColumns = mediaColumns + `,
	m.intro_start, m.intro_end, m.outro_start, m.outro_end,
	COALESCE(p.current_position_seconds, 0), COALESCE(p.is_finished, 0)`

// episodeItemColumns is libraryItemColumns for an episode: the poster falls
// back to the show's when the episode has none, and the season/show context the
// player needs to caption the episode comes along. It needs the season and
// show rows joined as `season` and `show_m`.
const episodeItemColumns = `m.id, m.type, m.title, COALESCE(m.file_path, ''), COALESCE(m.duration, 0),
	COALESCE(m.parent_id, 0),
	COALESCE(NULLIF(m.poster_url, ''), show_m.poster_url, '') AS poster_url,
	COALESCE(m.overview, ''), COALESCE(m.release_date, ''), COALESCE(m.tmdb_id, 0),
	COALESCE(m.imdb_id, ''), m.created_at,
	m.intro_start, m.intro_end, m.outro_start, m.outro_end,
	COALESCE(p.current_position_seconds, 0), COALESCE(p.is_finished, 0),
	COALESCE(NULLIF(m.season_number, 0), season.season_number, 0),
	COALESCE(m.episode_number, 0),
	COALESCE(season.title, ''), COALESCE(show_m.title, '')`

// The scanners below take a rowScanner (declared in permissions.go, alongside
// the userColumns/scanUser pair this file generalises), so a single-row lookup
// and a list query share the same mapping code.

// scanMedia reads one mediaColumns row. Trailing columns a caller added to the
// projection are passed as extra destinations, in order.
func scanMedia(row rowScanner, extra ...interface{}) (models.Media, error) {
	var m models.Media
	var parentID int

	dest := []interface{}{
		&m.ID, &m.Type, &m.Title, &m.FilePath, &m.Duration, &parentID,
		&m.PosterURL, &m.Overview, &m.ReleaseDate, &m.TMDBID, &m.IMDbID, &m.CreatedAt,
	}
	if err := row.Scan(append(dest, extra...)...); err != nil {
		return models.Media{}, err
	}

	// A NULL parent reads back as 0; the API distinguishes "no parent" (absent)
	// from an id, so it must stay a nil pointer rather than become 0.
	if parentID > 0 {
		m.ParentID = &parentID
	}
	return m, nil
}

// queryMediaList runs a mediaColumns query and drains it.
//
// It closes the cursor before returning, which matters more than it looks: the
// pool holds four connections and SQLite deadlocks if a query runs while rows
// from another are still open. The endpoints that ran two list queries in a row
// used to keep both cursors open until the handler returned.
func queryMediaList(context, query string, args ...interface{}) ([]models.Media, error) {
	rows, err := database.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMediaList(rows, context), nil
}

// scanMediaList drains a mediaColumns query, logging and skipping bad rows the
// way every hand-written loop did.
func scanMediaList(rows *sql.Rows, context string) []models.Media {
	results := []models.Media{}
	for rows.Next() {
		m, err := scanMedia(rows)
		if err != nil {
			log.Printf("%s: scan error: %v", context, err)
			continue
		}
		results = append(results, m)
	}
	if err := rows.Err(); err != nil {
		log.Printf("%s: row error: %v", context, err)
	}
	return results
}

// scanLibraryItem reads one libraryItemColumns row.
func scanLibraryItem(row rowScanner, extra ...interface{}) (models.HomeMediaItem, error) {
	var item models.HomeMediaItem
	var parentID int
	var isFinished int

	// Duration is deliberately scanned into the outer field: HomeMediaItem
	// redeclares it, and that is the one the JSON encoder emits.
	dest := []interface{}{
		&item.ID, &item.Type, &item.Title, &item.FilePath, &item.Duration, &parentID,
		&item.PosterURL, &item.Overview, &item.ReleaseDate, &item.TMDBID, &item.IMDbID,
		&item.CreatedAt,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&item.CurrentPositionSeconds, &isFinished,
	}
	if err := row.Scan(append(dest, extra...)...); err != nil {
		return models.HomeMediaItem{}, err
	}

	if parentID > 0 {
		item.ParentID = &parentID
	}
	item.IsFinished = isFinished != 0
	return item, nil
}

// scanEpisodeItem reads one episodeItemColumns row, applying the same
// season/episode-number recovery the endpoints used to repeat: the stored
// numbers win, and the title or filename is parsed only when they are missing.
func scanEpisodeItem(row rowScanner, extra ...interface{}) (models.HomeMediaItem, error) {
	var storedSeason, storedEpisode int
	var seasonTitle, showTitle string

	tail := append([]interface{}{
		&storedSeason, &storedEpisode, &seasonTitle, &showTitle,
	}, extra...)

	item, err := scanLibraryItem(row, tail...)
	if err != nil {
		return models.HomeMediaItem{}, err
	}

	item.SeasonNumber = resolveSeasonNumber(seasonTitle, item.FilePath, storedSeason)
	item.EpisodeNumber = parseEpisodeNumber(item.Title, storedEpisode)
	if showTitle != "" {
		item.ShowTitle = showTitle
	}
	return item, nil
}

// sqlPlaceholders returns "?, ?, …" for an IN clause of n values.
func sqlPlaceholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}
