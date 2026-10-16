package sharelinks

import (
	"fmt"
	"time"
)

// ViewerSummary dit au créateur d'un lien où en est l'un de ses spectateurs :
// le dernier média qu'il a regardé, et sa position dedans (ADR-0066). Le
// prénom est celui que le spectateur a donné ; il ne dit rien de plus de lui.
type ViewerSummary struct {
	Name    string
	MediaID int
	// SeasonNumber et EpisodeNumber valent 0 pour un film.
	SeasonNumber  int
	EpisodeNumber int
	// PositionSeconds vaut 0 quand le média est vu (Finished).
	PositionSeconds int
	Duration        int
	Finished        bool
	WatchedAt       time.Time
}

// ViewersByCreator renvoie, par id de lien, les spectateurs des liens créés
// par userID, du plus récent au moins récent. Une seule requête pour toute la
// liste : l'écran « Liens de partage » ne fait pas un aller-retour par lien.
func (s *Store) ViewersByCreator(userID int) (map[int][]ViewerSummary, error) {
	// La ligne la plus récente de chaque prénom est son dernier média
	// regardé ; à égalité d'instant, le même départage que Progress.
	rows, err := s.db.Query(`
		SELECT p.share_id, p.viewer_name, p.media_id, p.position_seconds, p.finished, p.updated_at,
			COALESCE(m.season_number, 0), COALESCE(m.episode_number, 0), COALESCE(m.duration, 0)
		FROM (
			SELECT share_id, viewer_name, media_id, position_seconds, finished, updated_at,
				ROW_NUMBER() OVER (
					PARTITION BY share_id, viewer_key
					ORDER BY updated_at DESC, media_id DESC) AS recency
			FROM media_share_progress
			WHERE share_id IN (SELECT id FROM media_shares WHERE created_by = ?)
		) p
		JOIN medias m ON m.id = p.media_id
		WHERE p.recency = 1
		ORDER BY p.share_id, p.updated_at DESC, p.viewer_name`, userID)
	if err != nil {
		return nil, fmt.Errorf("list share viewers of user %d: %w", userID, err)
	}
	defer rows.Close()

	out := map[int][]ViewerSummary{}
	for rows.Next() {
		var shareID int
		var updatedAt int64
		var v ViewerSummary
		if err := rows.Scan(&shareID, &v.Name, &v.MediaID, &v.PositionSeconds, &v.Finished, &updatedAt,
			&v.SeasonNumber, &v.EpisodeNumber, &v.Duration); err != nil {
			return nil, fmt.Errorf("scan share viewer: %w", err)
		}
		v.WatchedAt = time.UnixMilli(updatedAt)
		out[shareID] = append(out[shareID], v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list share viewers of user %d: %w", userID, err)
	}
	return out, nil
}
