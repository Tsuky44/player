package indexer

import (
	"strings"

	"project-player/server/database"
	"project-player/server/models"
)

// ResolveCanonicalShowID maps a show row id to the canonical library show when
// duplicates exist (same TMDB id or normalized title).
func ResolveCanonicalShowID(showID int) int {
	if showID <= 0 {
		return showID
	}
	var title string
	var tmdbID int
	err := database.DB.QueryRow(
		`SELECT title, COALESCE(tmdb_id, 0) FROM medias WHERE id = ? AND type = 'show'`,
		showID,
	).Scan(&title, &tmdbID)
	if err != nil {
		return showID
	}

	ids := collectDuplicateShowIDs(title, tmdbID)
	if len(ids) <= 1 {
		return showID
	}
	return pickCanonicalShowID(ids)
}

func collectDuplicateShowIDs(title string, tmdbID int) []int {
	if tmdbID > 0 {
		rows, err := database.DB.Query(
			`SELECT id FROM medias WHERE type = 'show' AND tmdb_id = ?`, tmdbID,
		)
		if err != nil {
			return []int{}
		}
		defer rows.Close()
		return scanIDList(rows)
	}

	key := normalizedShowDedupeKey(title, 0)
	rows, err := database.DB.Query(
		`SELECT id, title, COALESCE(tmdb_id, 0) FROM medias WHERE type = 'show'`,
	)
	if err != nil {
		return []int{}
	}
	defer rows.Close()

	var ids []int
	for rows.Next() {
		var id, tid int
		var t string
		if err := rows.Scan(&id, &t, &tid); err != nil {
			continue
		}
		if normalizedShowDedupeKey(t, tid) == key {
			ids = append(ids, id)
		}
	}
	return uniqueInts(ids)
}

func scanIDList(rows interface{ Next() bool; Scan(...interface{}) error }) []int {
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			continue
		}
		ids = append(ids, id)
	}
	return ids
}

// DedupeShowMediaList keeps one row per canonical show (TMDB id or normalized title).
func DedupeShowMediaList(shows []models.Media) []models.Media {
	if len(shows) <= 1 {
		return shows
	}

	groups := map[string][]models.Media{}
	for _, s := range shows {
		key := normalizedShowDedupeKey(s.Title, s.TMDBID)
		groups[key] = append(groups[key], s)
	}

	var out []models.Media
	for _, group := range groups {
		if len(group) == 1 {
			out = append(out, group[0])
			continue
		}
		ids := make([]int, 0, len(group))
		byID := map[int]models.Media{}
		for _, s := range group {
			ids = append(ids, s.ID)
			byID[s.ID] = s
		}
		canonical := pickCanonicalShowID(ids)
		out = append(out, byID[canonical])
	}
	return out
}

// ResolveCanonicalMovieID maps a movie row without a playable file onto another
// row for the same film.
//
// A row that has its own file is always returned as-is: several files may share
// a TMDB id (alternate versions, or a bad match), and redirecting them would
// show — and play — the wrong file.
func ResolveCanonicalMovieID(movieID int) int {
	if movieID <= 0 {
		return movieID
	}
	var tmdbID int
	var filePath string
	err := database.DB.QueryRow(
		`SELECT COALESCE(tmdb_id, 0), COALESCE(file_path, '') FROM medias WHERE id = ? AND type = 'movie'`,
		movieID,
	).Scan(&tmdbID, &filePath)
	if err != nil || tmdbID <= 0 || strings.TrimSpace(filePath) != "" {
		return movieID
	}
	rows, err := database.DB.Query(
		`SELECT id FROM medias
		 WHERE type = 'movie' AND tmdb_id = ? AND file_path IS NOT NULL AND file_path != ''
		 ORDER BY id ASC`, tmdbID,
	)
	if err != nil {
		return movieID
	}
	defer rows.Close()
	ids := scanIDList(rows)
	if len(ids) == 0 {
		return movieID
	}
	return ids[0]
}

// showDedupeKeyForMedia builds the dedupe key used by DedupeShowMediaList.
func showDedupeKeyForMedia(s models.Media) string {
	return normalizedShowDedupeKey(s.Title, s.TMDBID)
}

// PreferShowWithBetterPoster picks the show with a poster when merging duplicates for display.
func PreferShowWithBetterPoster(a, b models.Media) models.Media {
	aPoster := strings.TrimSpace(a.PosterURL)
	bPoster := strings.TrimSpace(b.PosterURL)
	if aPoster == "" && bPoster != "" {
		return b
	}
	if bPoster == "" && aPoster != "" {
		return a
	}
	if a.TMDBID > 0 && b.TMDBID == 0 {
		return a
	}
	if b.TMDBID > 0 && a.TMDBID == 0 {
		return b
	}
	return a
}

// DedupeShowMediaListForDisplay dedupes UI lists by normalized show title and maps
// to the canonical library id (episodes/seasons hang off the canonical row).
func DedupeShowMediaListForDisplay(shows []models.Media) []models.Media {
	if len(shows) <= 1 {
		return shows
	}
	groups := map[string][]models.Media{}
	for _, s := range shows {
		key := normalizedShowListKey(s)
		groups[key] = append(groups[key], s)
	}
	var out []models.Media
	for _, group := range groups {
		if len(group) == 1 {
			out = append(out, group[0])
			continue
		}
		ids := make([]int, 0, len(group))
		for _, s := range group {
			ids = append(ids, s.ID)
		}
		canonicalID := safePickCanonicalShowID(ids)
		best := group[0]
		for _, s := range group[1:] {
			best = PreferShowWithBetterPoster(best, s)
		}
		for _, s := range group {
			if s.ID == canonicalID {
				best = PreferShowWithBetterPoster(s, best)
				break
			}
		}
		best.ID = canonicalID
		for _, s := range group {
			if s.ID == canonicalID {
				if s.TMDBID > 0 {
					best.TMDBID = s.TMDBID
				}
				if strings.TrimSpace(best.PosterURL) == "" && strings.TrimSpace(s.PosterURL) != "" {
					best.PosterURL = s.PosterURL
				}
				if strings.TrimSpace(best.Overview) == "" && strings.TrimSpace(s.Overview) != "" {
					best.Overview = s.Overview
				}
				break
			}
		}
		out = append(out, best)
	}
	return out
}

func normalizedShowListKey(s models.Media) string {
	title := strings.TrimSpace(ReleaseDisplayTitle(StripProviderIDs(s.Title), models.TypeShow))
	if title == "" {
		title = strings.TrimSpace(s.Title)
	}
	return strings.ToLower(title)
}

func safePickCanonicalShowID(ids []int) int {
	if len(ids) == 0 {
		return 0
	}
	if len(ids) == 1 {
		return ids[0]
	}
	if database.DB == nil {
		return ids[0]
	}
	return pickCanonicalShowID(ids)
}
