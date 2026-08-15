package indexer

import (
	"log"
	"os"
	"path/filepath"
	"strings"

	"project-player/server/database"
	"project-player/server/models"
)

// DedupeDuplicateMovies merges movie rows that point at the same physical file,
// keeping a single canonical entry and migrating watch progress onto it.
func DedupeDuplicateMovies() {
	dedupeDuplicateMovies()
}

type movieRow struct {
	id       int
	filePath string
}

// dedupeDuplicateMovies only removes rows that are genuinely redundant: two rows
// for the same file, or a row whose file is gone while a sibling still has one.
//
// Sharing a TMDB id is NOT enough. Two different files can legitimately map to
// the same film (1080p + 4K versions), and a mis-identification also produces
// that shape — deleting on that basis silently erased real films from the
// library. Extra copies are reported instead, and both stay playable.
func dedupeDuplicateMovies() {
	// Load the groups first — never hold a rows cursor open while issuing the
	// UPDATE/DELETE below (SQLite uses a single connection and would deadlock).
	rows, err := database.DB.Query(`
		SELECT tmdb_id, GROUP_CONCAT(id)
		FROM medias
		WHERE type = 'movie' AND tmdb_id IS NOT NULL AND tmdb_id > 0
		GROUP BY tmdb_id
		HAVING COUNT(*) > 1`)
	if err != nil {
		log.Printf("Indexer dedupe: movie query failed: %v", err)
		return
	}

	var groups [][]int
	for rows.Next() {
		var tmdbID int
		var idList string
		if err := rows.Scan(&tmdbID, &idList); err != nil {
			continue
		}
		ids := parseIDList(idList)
		if len(ids) >= 2 {
			groups = append(groups, ids)
		}
	}
	rows.Close()

	merged := 0
	versions := 0
	for _, ids := range groups {
		live := loadExistingMovieRows(ids)
		if len(live) < 2 {
			continue
		}
		removable := redundantMovieIDs(live)
		if len(removable) == 0 {
			versions++
			log.Printf("Indexer dedupe: %d distinct files share the same TMDB id — kept as separate versions (%s)",
				len(live), summarizePaths(live))
			continue
		}
		canonical := pickCanonicalMovieID(keepableMovieIDs(live, removable))
		for _, id := range removable {
			if id == canonical {
				continue
			}
			if err := mergeDuplicateMovie(canonical, id); err != nil {
				log.Printf("Indexer dedupe: failed to merge movie %d into %d: %v", id, canonical, err)
				continue
			}
			merged++
			log.Printf("Indexer dedupe: merged redundant movie %d into %d", id, canonical)
		}
	}
	if merged > 0 {
		log.Printf("Indexer dedupe: merged %d redundant movie row(s)", merged)
	}
	if versions > 0 {
		log.Printf("Indexer dedupe: %d film(s) kept with multiple versions", versions)
	}
}

// RedetectAmbiguousMovies re-identifies films that share a TMDB id while their
// filenames say they are different films.
//
// That shape is the fingerprint of a bad match (a whole folder identified from
// its category name, for instance). Alternate versions of the same film — same
// parsed title, different quality — are left untouched.
func RedetectAmbiguousMovies() int {
	rows, err := database.DB.Query(`
		SELECT tmdb_id, GROUP_CONCAT(id)
		FROM medias
		WHERE type = 'movie' AND tmdb_id IS NOT NULL AND tmdb_id > 0
		GROUP BY tmdb_id
		HAVING COUNT(*) > 1`)
	if err != nil {
		log.Printf("Indexer: ambiguous movie query failed: %v", err)
		return 0
	}
	var groups [][]int
	for rows.Next() {
		var tmdbID int
		var idList string
		if err := rows.Scan(&tmdbID, &idList); err != nil {
			continue
		}
		if ids := parseIDList(idList); len(ids) >= 2 {
			groups = append(groups, ids)
		}
	}
	rows.Close()

	fixed := 0
	for _, ids := range groups {
		live := loadExistingMovieRows(ids)
		if len(live) < 2 || !filesLookLikeDifferentMovies(live) {
			continue
		}
		log.Printf("Indexer: %d files share one TMDB id but look like different films — re-identifying", len(live))
		for _, row := range live {
			if RedetectMediaByID(row.id) {
				fixed++
			}
		}
	}
	if fixed > 0 {
		log.Printf("Indexer: re-identified %d ambiguous movie(s)", fixed)
	}
	return fixed
}

// filesLookLikeDifferentMovies compares the titles parsed from the filenames.
func filesLookLikeDifferentMovies(rows []movieRow) bool {
	titles := map[string]bool{}
	for _, row := range rows {
		base := strings.TrimSuffix(filepath.Base(row.filePath), filepath.Ext(row.filePath))
		key, _, _ := MultipartKey(base)
		parsed := ParseReleaseFilename(key, models.TypeMovie)
		titles[strings.ToLower(strings.TrimSpace(parsed.Title))] = true
	}
	return len(titles) > 1
}

// redundantMovieIDs returns rows safe to delete: duplicates of a path already
// held by another row, and rows whose file no longer exists while a sibling's does.
func redundantMovieIDs(live []movieRow) []int {
	seenPath := map[string]int{}
	var removable []int
	var withFile, withoutFile []int

	for _, row := range live {
		key := normalizedPathKey(row.filePath)
		if key == "" {
			withoutFile = append(withoutFile, row.id)
			continue
		}
		if _, dup := seenPath[key]; dup {
			removable = append(removable, row.id)
			continue
		}
		seenPath[key] = row.id
		if fileExists(row.filePath) {
			withFile = append(withFile, row.id)
		} else {
			withoutFile = append(withoutFile, row.id)
		}
	}

	// Stale rows only go away when a real file survives for this film.
	if len(withFile) > 0 {
		removable = append(removable, withoutFile...)
	}
	return removable
}

func keepableMovieIDs(live []movieRow, removable []int) []int {
	drop := map[int]bool{}
	for _, id := range removable {
		drop[id] = true
	}
	var keep []int
	for _, row := range live {
		if !drop[row.id] {
			keep = append(keep, row.id)
		}
	}
	if len(keep) == 0 && len(live) > 0 {
		keep = append(keep, live[0].id)
	}
	return keep
}

func normalizedPathKey(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	return strings.ToLower(filepath.ToSlash(filepath.Clean(path)))
}

func fileExists(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

func summarizePaths(rows []movieRow) string {
	var names []string
	for _, r := range rows {
		names = append(names, filepath.Base(r.filePath))
		if len(names) >= 4 {
			break
		}
	}
	return strings.Join(names, ", ")
}

func loadExistingMovieRows(ids []int) []movieRow {
	var live []movieRow
	for _, id := range ids {
		var path string
		err := database.DB.QueryRow(
			`SELECT COALESCE(file_path, '') FROM medias WHERE id = ? AND type = 'movie'`, id,
		).Scan(&path)
		if err == nil {
			live = append(live, movieRow{id: id, filePath: path})
		}
	}
	return live
}

// pickCanonicalMovieID prefers the entry that carries watch progress, then the
// lowest id for stability.
func pickCanonicalMovieID(ids []int) int {
	canonical := ids[0]
	bestScore := movieProgressScore(canonical)
	for _, id := range ids[1:] {
		score := movieProgressScore(id)
		if score > bestScore || (score == bestScore && id < canonical) {
			canonical = id
			bestScore = score
		}
	}
	return canonical
}

func movieProgressScore(id int) int {
	var count int
	_ = database.DB.QueryRow(
		`SELECT COUNT(*) FROM progressions WHERE media_id = ? AND current_position_seconds > 0`, id,
	).Scan(&count)
	return count
}

func mergeDuplicateMovie(canonicalID, duplicateID int) error {
	if canonicalID == duplicateID {
		return nil
	}

	// Move watch progress onto the canonical row unless it already has some for
	// that user (OR IGNORE keeps the canonical's existing progression).
	if _, err := database.DB.Exec(
		`UPDATE OR IGNORE progressions SET media_id = ? WHERE media_id = ?`,
		canonicalID, duplicateID,
	); err != nil {
		return err
	}
	if _, err := database.DB.Exec(`DELETE FROM progressions WHERE media_id = ?`, duplicateID); err != nil {
		return err
	}

	_, err := database.DB.Exec(`DELETE FROM medias WHERE id = ? AND type = 'movie'`, duplicateID)
	return err
}
