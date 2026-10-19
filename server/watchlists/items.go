package watchlists

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"project-player/server/models"
)

// identity est ce qui fait qu'un élément est « ce titre-là » : son identité
// TMDB quand on la connaît, la fiche du serveur sinon. Deux ajouts du même
// titre, l'un depuis le catalogue et l'autre depuis la fiche, se reconnaissent
// par leur tmdb_id.
type identity struct {
	mediaType string
	tmdbID    int
	mediaID   int
}

// snapshot est ce qu'un élément montre quand il ne se rattache à aucune fiche.
type snapshot struct {
	title       string
	posterURL   string
	releaseDate string
}

// matchClause trouve les éléments d'une identité, à compléter par matchArgs.
// Un élément du catalogue (tmdb_id) se reconnaît aussi par une fiche du
// serveur qui porte ce tmdb_id, et inversement.
const matchClause = `(
	(? > 0 AND tmdb_id = ? AND media_type = ?)
	OR (? > 0 AND media_id = ?)
	OR (? > 0 AND media_id IN (SELECT id FROM medias WHERE tmdb_id = ? AND type = ?))
)`

func (id identity) matchArgs() []interface{} {
	return []interface{}{
		id.tmdbID, id.tmdbID, id.mediaType,
		id.mediaID, id.mediaID,
		id.tmdbID, id.tmdbID, id.mediaType,
	}
}

// mediaIdentity lit une fiche du serveur : seuls un film ou une série vont
// dans une liste.
func mediaIdentity(q querier, mediaID int) (identity, snapshot, error) {
	var id identity
	var snap snapshot
	err := q.QueryRow(`
		SELECT type, COALESCE(tmdb_id, 0), title, COALESCE(poster_url, ''), COALESCE(release_date, '')
		FROM medias WHERE id = ?`, mediaID).
		Scan(&id.mediaType, &id.tmdbID, &snap.title, &snap.posterURL, &snap.releaseDate)
	if errors.Is(err, sql.ErrNoRows) {
		return identity{}, snapshot{}, ErrNotFound
	}
	if err != nil {
		return identity{}, snapshot{}, fmt.Errorf("load media %d: %w", mediaID, err)
	}
	if !listableType(id.mediaType) {
		return identity{}, snapshot{}, ErrInvalid
	}
	id.mediaID = mediaID
	return id, snap, nil
}

func probeIdentity(q querier, p Probe) (identity, bool, error) {
	if p.MediaID > 0 {
		id, _, err := mediaIdentity(q, p.MediaID)
		if errors.Is(err, ErrNotFound) || errors.Is(err, ErrInvalid) {
			return identity{}, false, nil
		}
		return id, err == nil, err
	}
	mediaType := p.MediaType
	if mediaType == "tv" {
		mediaType = string(models.TypeShow)
	}
	if p.TMDBID <= 0 || !listableType(mediaType) {
		return identity{}, false, nil
	}
	return identity{mediaType: mediaType, tmdbID: p.TMDBID}, true, nil
}

// markContains dit, pour chaque liste, l'élément qui porte le titre demandé
// (0 s'il n'y est pas).
func (s *Store) markContains(lists []models.WatchList, p Probe) error {
	if len(lists) == 0 {
		return nil
	}
	id, ok, err := probeIdentity(s.db, p)
	if err != nil {
		return err
	}
	found := map[int]int{}
	if ok {
		ids := make([]int, len(lists))
		for i, l := range lists {
			ids[i] = l.ID
		}
		rows, err := s.db.Query(fmt.Sprintf(`
			SELECT list_id, MIN(id) FROM watch_list_items
			WHERE list_id IN (%s) AND `+matchClause+`
			GROUP BY list_id`, placeholders(len(ids))), append(intArgs(ids), id.matchArgs()...)...)
		if err != nil {
			return fmt.Errorf("find title in watch lists: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var listID, itemID int
			if err := rows.Scan(&listID, &itemID); err != nil {
				return fmt.Errorf("scan watch list match: %w", err)
			}
			found[listID] = itemID
		}
		if err := rows.Err(); err != nil {
			return fmt.Errorf("find title in watch lists: %w", err)
		}
	}
	for i := range lists {
		itemID := found[lists[i].ID]
		lists[i].ContainsItemID = &itemID
	}
	return nil
}

// AddServerMedia ajoute une fiche du serveur à une liste du compte.
func (s *Store) AddServerMedia(ownerID, listID, mediaID int) (models.WatchListItem, error) {
	if mediaID <= 0 {
		return models.WatchListItem{}, ErrInvalid
	}
	return s.add(ownerID, listID, func(q querier) (identity, snapshot, error) {
		id, snap, err := mediaIdentity(q, mediaID)
		if errors.Is(err, ErrNotFound) {
			// La liste existe ; c'est la fiche qui manque.
			return identity{}, snapshot{}, ErrInvalid
		}
		return id, snap, err
	})
}

// AddCatalogTitle ajoute un titre du catalogue TMDB, que le serveur ait ou non
// sa fiche.
func (s *Store) AddCatalogTitle(ownerID, listID int, t CatalogTitle) (models.WatchListItem, error) {
	t, err := normalizeCatalogTitle(t)
	if err != nil {
		return models.WatchListItem{}, err
	}
	poster := ""
	if t.PosterPath != "" {
		poster = tmdbPosterBase + t.PosterPath
	}
	return s.add(ownerID, listID, func(querier) (identity, snapshot, error) {
		return identity{mediaType: t.MediaType, tmdbID: t.TMDBID},
			snapshot{title: t.Title, posterURL: poster, releaseDate: t.ReleaseDate}, nil
	})
}

// add range un titre dans une liste du compte. Un titre déjà présent n'est
// pas doublé : l'élément existant est renvoyé tel quel.
func (s *Store) add(ownerID, listID int, resolve func(querier) (identity, snapshot, error)) (models.WatchListItem, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return models.WatchListItem{}, fmt.Errorf("add watch list item: begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // sans effet une fois validée
	if _, err := s.ownedKind(tx, ownerID, listID); err != nil {
		return models.WatchListItem{}, err
	}
	id, snap, err := resolve(tx)
	if err != nil {
		return models.WatchListItem{}, err
	}

	existing, err := findItem(tx, listID, id)
	if err != nil {
		return models.WatchListItem{}, err
	}
	if existing == 0 {
		var count int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM watch_list_items WHERE list_id = ?`, listID).Scan(&count); err != nil {
			return models.WatchListItem{}, fmt.Errorf("count watch list items: %w", err)
		}
		if count >= MaxItemsPerList {
			return models.WatchListItem{}, ErrTooMany
		}
		var mediaID interface{}
		if id.mediaID > 0 {
			mediaID = id.mediaID
		}
		now := s.nowMillis()
		res, err := tx.Exec(`
			INSERT INTO watch_list_items (list_id, media_type, media_id, tmdb_id, title, poster_url, release_date, added_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			listID, id.mediaType, mediaID, id.tmdbID, snap.title, snap.posterURL, snap.releaseDate, now)
		switch {
		case isUniqueViolation(err):
			// Un autre appareil vient d'ajouter le même titre : SQLite n'a
			// annulé que cette instruction, l'élément qu'il a rangé se relit.
			if existing, err = findItem(tx, listID, id); err != nil {
				return models.WatchListItem{}, err
			}
		case err != nil:
			return models.WatchListItem{}, fmt.Errorf("insert watch list item: %w", err)
		default:
			itemID, err := res.LastInsertId()
			if err != nil {
				return models.WatchListItem{}, fmt.Errorf("watch list item id: %w", err)
			}
			existing = int(itemID)
		}
		if _, err := tx.Exec(`UPDATE watch_lists SET updated_at = ? WHERE id = ?`, now, listID); err != nil {
			return models.WatchListItem{}, fmt.Errorf("touch watch list: %w", err)
		}
	}

	items, err := s.items(tx, listID, existing)
	if err != nil {
		return models.WatchListItem{}, err
	}
	if len(items) == 0 {
		return models.WatchListItem{}, fmt.Errorf("watch list item %d vanished", existing)
	}
	if err := tx.Commit(); err != nil {
		return models.WatchListItem{}, fmt.Errorf("add watch list item: commit: %w", err)
	}
	return items[0], nil
}

// findItem renvoie l'élément de la liste qui porte ce titre, 0 s'il n'y est
// pas.
func findItem(q querier, listID int, id identity) (int, error) {
	var itemID int
	err := q.QueryRow(`
		SELECT id FROM watch_list_items
		WHERE list_id = ? AND `+matchClause+`
		ORDER BY id LIMIT 1`, append([]interface{}{listID}, id.matchArgs()...)...).Scan(&itemID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("find watch list item: %w", err)
	}
	return itemID, nil
}

// RemoveItem retire un élément d'une liste du compte.
func (s *Store) RemoveItem(ownerID, listID, itemID int) error {
	if _, err := s.ownedKind(s.db, ownerID, listID); err != nil {
		return err
	}
	res, err := s.db.Exec(`DELETE FROM watch_list_items WHERE id = ? AND list_id = ?`, itemID, listID)
	if err != nil {
		return fmt.Errorf("delete watch list item: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("delete watch list item: %w", err)
	} else if n == 0 {
		return ErrNotFound
	}
	if _, err := s.db.Exec(`UPDATE watch_lists SET updated_at = ? WHERE id = ?`, s.nowMillis(), listID); err != nil {
		return fmt.Errorf("touch watch list: %w", err)
	}
	return nil
}

// isUniqueViolation dit si SQLite a refusé une ligne pour un index unique.
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
