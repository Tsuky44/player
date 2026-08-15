package indexer

import (
	"log"
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/models"
)

// showFolderNameFromParts returns the folder that names the series: the deepest
// one that is not a season folder, a release folder or a grouping folder.
//
// Walking from the deepest folder up is what makes nested libraries work
// ("Séries/Animes/Naruto/Saison 1/…" is Naruto, not Animes); taking the first
// folder instead merged every show of a category into one series.
func showFolderNameFromParts(parts []string) (string, bool) {
	for i := len(parts) - 2; i >= 0; i-- {
		part := strings.TrimSpace(parts[i])
		if part == "" || looksLikeEpisodeReleaseFolder(part) || looksLikeSeasonFolderName(part) {
			continue
		}
		if looksLikeCategoryFolderName(part) || bareNumberRe.MatchString(part) {
			continue
		}
		return part, true
	}
	// Second pass: a numeric folder can be the show itself ("24", "1883").
	for i := len(parts) - 2; i >= 0; i-- {
		part := strings.TrimSpace(parts[i])
		if part == "" || looksLikeEpisodeReleaseFolder(part) || looksLikeSeasonFolderName(part) {
			continue
		}
		if looksLikeCategoryFolderName(part) {
			continue
		}
		return part, true
	}
	return "", false
}

// looksLikeSeasonFolderName matches "Season 1", "Saison 02", "S01", "Series 3".
func looksLikeSeasonFolderName(name string) bool {
	name = strings.TrimSpace(name)
	if seasonFolderRe.MatchString(name) {
		return true
	}
	lower := strings.ToLower(name)
	return strings.HasPrefix(lower, "season ") || strings.HasPrefix(lower, "saison ") ||
		lower == "specials" || lower == "saison 0"
}

// resolveShowTMDBSearchKeyFromPath returns a raw release string (year preserved)
// for TMDB lookup. Display titles are normalized separately for deduplication.
func resolveShowTMDBSearchKeyFromPath(parts []string, fileName string) string {
	if folder, ok := showFolderNameFromParts(parts); ok {
		return folder
	}

	loc := episodeRegex.FindStringIndex(fileName)
	if loc != nil {
		return strings.Trim(fileName[:loc[0]], " -_.")
	}
	return strings.TrimSuffix(fileName, filepath.Ext(fileName))
}
func looksLikeEpisodeReleaseFolder(name string) bool {
	if _, _, ok := ParseEpisodeNumbers(name); ok {
		return true
	}
	if episodeRegex.MatchString(name) {
		return true
	}
	lower := strings.ToLower(name)
	if strings.Contains(lower, "season ") || strings.Contains(lower, "saison ") {
		return true
	}
	return false
}

// resolveShowTitleFromPath picks a stable show name from the series folder layout.
// Per-episode download folders are ignored in favour of a parent folder or filename.
func resolveShowTitleFromPath(parts []string, fileName string) string {
	if folder, ok := showFolderNameFromParts(parts); ok {
		if title := ReleaseDisplayTitle(StripProviderIDs(folder), models.TypeShow); title != "" {
			return title
		}
	}

	loc := episodeRegex.FindStringIndex(fileName)
	if loc != nil {
		raw := strings.Trim(fileName[:loc[0]], " -_.")
		if title := ReleaseDisplayTitle(raw, models.TypeShow); title != "" {
			return title
		}
	}

	return "Unknown Show"
}

func lookupShowIDByTitle(title string) (int, bool) {
	title = strings.TrimSpace(title)
	if title == "" {
		return 0, false
	}
	var id int
	err := database.DB.QueryRow(
		`SELECT id FROM medias
		 WHERE type = ? AND LOWER(TRIM(title)) = LOWER(TRIM(?))
		 ORDER BY id ASC LIMIT 1`,
		models.TypeShow, title,
	).Scan(&id)
	return id, err == nil
}

func lookupShowIDByTMDBID(tmdbID int) (int, bool) {
	if tmdbID <= 0 {
		return 0, false
	}
	var id int
	err := database.DB.QueryRow(
		`SELECT id FROM medias
		 WHERE type = ? AND tmdb_id = ?
		 ORDER BY id ASC LIMIT 1`,
		models.TypeShow, tmdbID,
	).Scan(&id)
	return id, err == nil
}

// findOrCreateShow resolves a show by local provider IDs / NFO first (Emby-style),
// then TMDB id, then normalized title. tmdbSearchKey should preserve years when available.
func findOrCreateShow(displayTitle, tmdbSearchKey, showFolderPath string) (int, error) {
	displayTitle = strings.TrimSpace(displayTitle)
	if displayTitle == "" {
		displayTitle = "Unknown Show"
	}
	tmdbSearchKey = strings.TrimSpace(tmdbSearchKey)
	if tmdbSearchKey == "" {
		tmdbSearchKey = displayTitle
	}

	identity := IdentifyShow(showFolderPath, tmdbSearchKey)
	if identity.Matched && identity.Title != "" {
		displayTitle = identity.Title
	} else {
		normalizedSearch := ReleaseDisplayTitle(StripProviderIDs(displayTitle), models.TypeShow)
		if normalizedSearch != "" {
			displayTitle = normalizedSearch
		}
	}

	// Prefer TMDB id binding over title-only, to avoid attaching to a wrong early match.
	if identity.Matched && identity.TMDBID > 0 {
		if id, ok := lookupShowIDByTMDBID(identity.TMDBID); ok {
			ensureShowHasTMDBID(id)
			if identity.IMDbID != "" {
				_, _ = database.DB.Exec(`UPDATE medias SET imdb_id = COALESCE(NULLIF(imdb_id, ''), ?) WHERE id = ?`, identity.IMDbID, id)
			}
			return id, nil
		}
	}

	if id, ok := lookupShowIDByTitle(displayTitle); ok {
		ensureShowHasTMDBID(id)
		return id, nil
	}

	tmdbID := 0
	posterURL, overview, releaseDate := "", "", ""
	imdbID := identity.IMDbID
	if identity.Matched {
		tmdbID = identity.TMDBID
		posterURL = identity.PosterURL
		overview = identity.Overview
		releaseDate = identity.ReleaseDate
	}

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, poster_url, overview, release_date, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
		models.TypeShow, displayTitle, posterURL, overview, releaseDate, tmdbID, nullIfEmpty(imdbID),
	)
	if err != nil {
		return 0, err
	}

	insertID, err := res.LastInsertId()
	if err == nil {
		if identity.Matched {
			log.Printf("Indexer: created show %q (tmdb=%d via %s, conf=%.2f)", displayTitle, tmdbID, identity.Source, identity.Confidence)
		} else {
			log.Printf("Indexer: created show %q (unmatched — needs review)", displayTitle)
		}
	}
	return int(insertID), err
}

func countEpisodesUnderShow(showID int) int {
	var count int
	_ = database.DB.QueryRow(`
		SELECT COUNT(*)
		FROM medias ep
		JOIN medias season ON ep.parent_id = season.id AND season.type = 'season'
		WHERE ep.type = 'episode' AND season.parent_id = ?`, showID,
	).Scan(&count)
	return count
}

func mergeDuplicateShow(canonicalID, duplicateID int) error {
	if canonicalID == duplicateID {
		return nil
	}

	if err := mergeDuplicateShowSeasons(canonicalID, duplicateID); err != nil {
		return err
	}
	if err := mergeDuplicateShowDirectEpisodes(canonicalID, duplicateID); err != nil {
		return err
	}

	_, err := database.DB.Exec(`DELETE FROM medias WHERE id = ? AND type = 'show'`, duplicateID)
	return err
}

func mergeDuplicateShowSeasons(canonicalID, duplicateID int) error {
	rows, err := database.DB.Query(
		`SELECT id, COALESCE(season_number, 0), title
		 FROM medias WHERE type = 'season' AND parent_id = ?`,
		duplicateID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()

	type seasonRow struct {
		id        int
		seasonNum int
		title     string
	}
	var seasons []seasonRow

	for rows.Next() {
		var s seasonRow
		if err := rows.Scan(&s.id, &s.seasonNum, &s.title); err != nil {
			return err
		}
		if s.seasonNum == 0 {
			s.seasonNum = parseSeasonNumberFromTitle(s.title)
		}
		seasons = append(seasons, s)
	}

	for _, s := range seasons {
		if s.seasonNum <= 0 {
			log.Printf("Indexer dedupe: skip season %d on show %d — unknown season number", s.id, duplicateID)
			continue
		}

		canonSeasonID, err := findOrCreateSeason(canonicalID, s.seasonNum)
		if err != nil {
			return err
		}

		if _, err := database.DB.Exec(
			`UPDATE medias SET parent_id = ? WHERE type = 'episode' AND parent_id = ?`,
			canonSeasonID, s.id,
		); err != nil {
			return err
		}

		if _, err := database.DB.Exec(`DELETE FROM medias WHERE id = ? AND type = 'season'`, s.id); err != nil {
			return err
		}
	}
	return nil
}

func mergeDuplicateShowDirectEpisodes(canonicalID, duplicateID int) error {
	rows, err := database.DB.Query(
		`SELECT id, COALESCE(season_number, 0), COALESCE(episode_number, 0), COALESCE(file_path, ''), title
		 FROM medias WHERE type = 'episode' AND parent_id = ?`,
		duplicateID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var episodeID, seasonNum, episodeNum int
		var filePath, title string
		if err := rows.Scan(&episodeID, &seasonNum, &episodeNum, &filePath, &title); err != nil {
			return err
		}
		if seasonNum == 0 {
			if s, _, ok := ParseEpisodeNumbers(filepathBase(filePath)); ok {
				seasonNum = s
			}
		}
		if seasonNum == 0 {
			if s, _, ok := ParseEpisodeNumbers(title); ok {
				seasonNum = s
			}
		}
		if seasonNum <= 0 {
			log.Printf("Indexer dedupe: skip direct episode %d on show %d — unknown season", episodeID, duplicateID)
			continue
		}

		canonSeasonID, err := findOrCreateSeason(canonicalID, seasonNum)
		if err != nil {
			return err
		}
		if _, err := database.DB.Exec(
			`UPDATE medias SET parent_id = ? WHERE id = ? AND type = 'episode'`,
			canonSeasonID, episodeID,
		); err != nil {
			return err
		}
	}
	return nil
}

func filepathBase(path string) string {
	path = strings.ReplaceAll(path, "\\", "/")
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

// DedupeDuplicateShows merges duplicate TV show rows (same TMDB id or normalized title).
func DedupeDuplicateShows() {
	dedupeDuplicateShows()
}

func dedupeDuplicateShows() {
	var totalShows int
	_ = database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type = 'show'`).Scan(&totalShows)
	log.Printf("Indexer dedupe: checking %d show(s)…", totalShows)

	ensureAllShowsHaveTMDBIDs()

	merged := 0
	merged += dedupeShowGroups(`
		SELECT tmdb_id, GROUP_CONCAT(id)
		FROM medias
		WHERE type = 'show' AND tmdb_id IS NOT NULL AND tmdb_id > 0
		GROUP BY tmdb_id
		HAVING COUNT(*) > 1`)
	merged += dedupeByNormalizedTitle()
	merged += dedupeShowGroups(`
		SELECT LOWER(TRIM(title)), GROUP_CONCAT(id)
		FROM medias
		WHERE type = 'show'
		GROUP BY LOWER(TRIM(title))
		HAVING COUNT(*) > 1`)

	if merged > 0 {
		cleanEmptySeasonsAndShows()
	}
	log.Printf("Indexer dedupe: finished, merged %d duplicate show(s)", merged)
}

func ensureAllShowsHaveTMDBIDs() {
	rows, err := database.DB.Query(`
		SELECT id FROM medias
		WHERE type = 'show' AND (tmdb_id IS NULL OR tmdb_id = 0)`)
	if err != nil {
		log.Printf("Indexer dedupe: TMDB backfill query failed: %v", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			continue
		}
		ensureShowHasTMDBID(id)
	}
}

func normalizedShowDedupeKey(title string, tmdbID int) string {
	if tmdbID > 0 {
		return "tmdb:" + strconv.Itoa(tmdbID)
	}
	normalized := strings.ToLower(strings.TrimSpace(ReleaseDisplayTitle(title, models.TypeShow)))
	if normalized == "" {
		normalized = strings.ToLower(strings.TrimSpace(title))
	}
	return "title:" + normalized
}

func dedupeByNormalizedTitle() int {
	rows, err := database.DB.Query(`
		SELECT id, title, COALESCE(tmdb_id, 0)
		FROM medias WHERE type = 'show'`)
	if err != nil {
		log.Printf("Indexer dedupe: normalized title query failed: %v", err)
		return 0
	}
	defer rows.Close()

	groups := map[string][]int{}
	for rows.Next() {
		var id, tmdbID int
		var title string
		if err := rows.Scan(&id, &title, &tmdbID); err != nil {
			log.Printf("Indexer dedupe: normalized title scan failed: %v", err)
			return 0
		}
		key := normalizedShowDedupeKey(title, tmdbID)
		groups[key] = append(groups[key], id)
	}

	merged := 0
	for key, ids := range groups {
		unique := uniqueInts(ids)
		if len(unique) < 2 {
			continue
		}
		live := filterExistingShowIDs(unique)
		if len(live) < 2 {
			continue
		}
		canonical := pickCanonicalShowID(live)
		for _, id := range live {
			if id == canonical {
				continue
			}
			if err := mergeDuplicateShow(canonical, id); err != nil {
				log.Printf("Indexer dedupe: failed to merge show %d into %d (%s): %v", id, canonical, key, err)
				continue
			}
			merged++
			log.Printf("Indexer dedupe: merged duplicate show %d into %d (%s)", id, canonical, key)
		}
	}
	return merged
}

func dedupeShowGroups(query string) int {
	rows, err := database.DB.Query(query)
	if err != nil {
		log.Printf("Indexer dedupe: query failed: %v", err)
		return 0
	}
	defer rows.Close()

	merged := 0
	for rows.Next() {
		var key string
		var idList string
		if err := rows.Scan(&key, &idList); err != nil {
			log.Printf("Indexer dedupe: scan failed: %v", err)
			continue
		}

		ids := parseIDList(idList)
		if len(ids) < 2 {
			continue
		}

		live := filterExistingShowIDs(ids)
		if len(live) < 2 {
			continue
		}

		canonical := pickCanonicalShowID(live)
		for _, id := range live {
			if id == canonical {
				continue
			}
			if err := mergeDuplicateShow(canonical, id); err != nil {
				log.Printf("Indexer dedupe: failed to merge show %d into %d (%s): %v", id, canonical, key, err)
				continue
			}
			merged++
			log.Printf("Indexer dedupe: merged duplicate show %d into %d (%s)", id, canonical, key)
		}
	}
	return merged
}

func parseIDList(raw string) []int {
	parts := strings.Split(raw, ",")
	var ids []int
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, err := strconv.Atoi(part)
		if err != nil {
			continue
		}
		ids = append(ids, id)
	}
	return uniqueInts(ids)
}

func filterExistingShowIDs(ids []int) []int {
	var live []int
	for _, id := range ids {
		var exists bool
		err := database.DB.QueryRow(
			`SELECT EXISTS(SELECT 1 FROM medias WHERE id = ? AND type = 'show')`, id,
		).Scan(&exists)
		if err == nil && exists {
			live = append(live, id)
		}
	}
	return live
}

func pickCanonicalShowID(ids []int) int {
	canonical := ids[0]
	bestScore := countEpisodesUnderShow(canonical)
	for _, id := range ids[1:] {
		score := countEpisodesUnderShow(id)
		if score > bestScore || (score == bestScore && id < canonical) {
			canonical = id
			bestScore = score
		}
	}
	return canonical
}

func uniqueInts(values []int) []int {
	seen := map[int]bool{}
	var out []int
	for _, v := range values {
		if seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}
