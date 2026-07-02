package indexer

import (
	"log"

	"project-player/server/database"
)

// DedupeDuplicateMovies merges movie rows that resolve to the same TMDB movie,
// keeping a single canonical entry and migrating watch progress onto it.
func DedupeDuplicateMovies() {
	dedupeDuplicateMovies()
}

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
	for _, ids := range groups {
		live := filterExistingMovieIDs(ids)
		if len(live) < 2 {
			continue
		}
		canonical := pickCanonicalMovieID(live)
		for _, id := range live {
			if id == canonical {
				continue
			}
			if err := mergeDuplicateMovie(canonical, id); err != nil {
				log.Printf("Indexer dedupe: failed to merge movie %d into %d: %v", id, canonical, err)
				continue
			}
			merged++
			log.Printf("Indexer dedupe: merged duplicate movie %d into %d", id, canonical)
		}
	}
	if merged > 0 {
		log.Printf("Indexer dedupe: merged %d duplicate movie(s)", merged)
	}
}

func filterExistingMovieIDs(ids []int) []int {
	var live []int
	for _, id := range ids {
		var exists bool
		err := database.DB.QueryRow(
			`SELECT EXISTS(SELECT 1 FROM medias WHERE id = ? AND type = 'movie')`, id,
		).Scan(&exists)
		if err == nil && exists {
			live = append(live, id)
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
