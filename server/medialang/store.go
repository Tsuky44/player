package medialang

import (
	"fmt"
	"strings"

	"project-player/server/database"
)

// Text est ce qu'une fiche dit dans une langue. Un champ vide veut dire que
// TMDB n'a rien dans cette langue : le texte de base reste alors affiché.
type Text struct {
	Title    string
	Overview string
}

// SourceTMDBID est, en SQL, l'identité TMDB dont dépend la traduction de la
// ligne `m` : la sienne pour un film ou une série, celle de sa série pour un
// épisode. Elle attend les jointures de SourceJoins.
const SourceTMDBID = `COALESCE(CASE
		WHEN m.type != 'episode' THEN m.tmdb_id
		WHEN src_parent.type = 'show' THEN src_parent.tmdb_id
		ELSE src_show.tmdb_id END, 0)`

// SourceJoins remonte de `m` à sa série, que l'épisode pende à une saison ou
// directement à la série.
const SourceJoins = `
	LEFT JOIN medias src_parent ON m.type = 'episode' AND src_parent.id = m.parent_id
	LEFT JOIN medias src_show ON src_parent.type = 'season' AND src_show.id = src_parent.parent_id`

// Texts charge en une requête les traductions de plusieurs fiches. Une
// traduction tirée d'une autre identité TMDB que celle de la fiche aujourd'hui
// est ignorée : mieux vaut le texte de base que le synopsis d'un autre film.
func Texts(language string, ids []int) (map[int]Text, error) {
	out := make(map[int]Text, len(ids))
	if len(ids) == 0 {
		return out, nil
	}

	args := make([]interface{}, 0, len(ids)+1)
	args = append(args, language)
	for _, id := range ids {
		args = append(args, id)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?, ", len(ids)), ", ")

	rows, err := database.DB.Query(fmt.Sprintf(`
		SELECT t.media_id, t.title, t.overview
		FROM media_translations t
		JOIN medias m ON m.id = t.media_id`+SourceJoins+`
		WHERE t.language = ? AND t.media_id IN (%s)
		  AND t.source_tmdb_id = `+SourceTMDBID, placeholders), args...)
	if err != nil {
		return nil, fmt.Errorf("medialang: load translations: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var text Text
		if err := rows.Scan(&id, &text.Title, &text.Overview); err != nil {
			return nil, fmt.Errorf("medialang: scan translation: %w", err)
		}
		out[id] = text
	}
	return out, rows.Err()
}

// Save écrit la traduction d'une fiche, en remplaçant celle qui existait.
func Save(mediaID int, language string, sourceTMDBID int, text Text) error {
	_, err := database.DB.Exec(`
		INSERT INTO media_translations (media_id, language, source_tmdb_id, title, overview, fetched_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(media_id, language) DO UPDATE SET
			source_tmdb_id = excluded.source_tmdb_id,
			title = excluded.title,
			overview = excluded.overview,
			fetched_at = excluded.fetched_at`,
		mediaID, language, sourceTMDBID, strings.TrimSpace(text.Title), strings.TrimSpace(text.Overview))
	if err != nil {
		return fmt.Errorf("medialang: save translation of media %d (%s): %w", mediaID, language, err)
	}
	return nil
}

// Rebase suit un changement de langue de base. Les textes de medias restent
// dans l'ancienne langue tant que TMDB n'a pas été relu, et les traductions
// déjà en base dans la nouvelle ne servaient plus à rien : les deux
// s'échangent ici, sans un appel à TMDB. Une fiche sans traduction dans la
// nouvelle langue garde son texte, comme avant ce réglage.
func Rebase(oldCode, newCode string) error {
	if oldCode == newCode {
		return nil
	}
	if _, ok := localeOf(newCode); !ok {
		return nil // aucune traduction tenue dans cette langue
	}

	rows, err := database.DB.Query(`
		SELECT m.id, m.title, COALESCE(m.overview, ''), t.source_tmdb_id, t.title, t.overview
		FROM media_translations t
		JOIN medias m ON m.id = t.media_id`+SourceJoins+`
		WHERE t.language = ? AND t.title != ''
		  AND t.source_tmdb_id = `+SourceTMDBID, newCode)
	if err != nil {
		return fmt.Errorf("medialang: rebase: load translations: %w", err)
	}
	type swap struct {
		id, source  int
		base, fresh Text
	}
	var swaps []swap
	for rows.Next() {
		var s swap
		if err := rows.Scan(&s.id, &s.base.Title, &s.base.Overview, &s.source, &s.fresh.Title, &s.fresh.Overview); err != nil {
			rows.Close()
			return fmt.Errorf("medialang: rebase: scan: %w", err)
		}
		swaps = append(swaps, s)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("medialang: rebase: %w", err)
	}

	_, keepOld := localeOf(oldCode)
	tx, err := database.DB.Begin()
	if err != nil {
		return fmt.Errorf("medialang: rebase: begin: %w", err)
	}
	defer tx.Rollback()
	for _, s := range swaps {
		if keepOld {
			if _, err := tx.Exec(`
				INSERT INTO media_translations (media_id, language, source_tmdb_id, title, overview, fetched_at)
				VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
				ON CONFLICT(media_id, language) DO UPDATE SET
					source_tmdb_id = excluded.source_tmdb_id,
					title = excluded.title,
					overview = excluded.overview,
					fetched_at = excluded.fetched_at`,
				s.id, oldCode, s.source, s.base.Title, s.base.Overview); err != nil {
				return fmt.Errorf("medialang: rebase: keep %s text of media %d: %w", oldCode, s.id, err)
			}
		}
		overview := s.fresh.Overview
		if overview == "" {
			overview = s.base.Overview
		}
		if _, err := tx.Exec(`UPDATE medias SET title = ?, overview = ? WHERE id = ?`,
			s.fresh.Title, overview, s.id); err != nil {
			return fmt.Errorf("medialang: rebase: media %d: %w", s.id, err)
		}
	}
	if _, err := tx.Exec(`DELETE FROM media_translations WHERE language = ?`, newCode); err != nil {
		return fmt.Errorf("medialang: rebase: drop %s translations: %w", newCode, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("medialang: rebase: commit: %w", err)
	}
	return nil
}
