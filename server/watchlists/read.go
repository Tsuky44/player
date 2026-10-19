package watchlists

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"project-player/server/models"
)

// listColumns projette une liste et son propriétaire ; il faut joindre users
// sous `u`.
const listColumns = `w.id, w.kind, w.name, w.description, w.is_shared, w.owner_id,
	COALESCE(u.username, ''), w.updated_at`

// resolvedItems projette les éléments des listes demandées avec la fiche du
// serveur qui leur correspond (resolved_id, 0 sans fiche). Un élément connu de
// TMDB se rattache par tmdb_id, à la plus ancienne ligne quand un film a
// plusieurs versions : c'est ce qui rend lisible un titre ajouté avant
// d'arriver sur le serveur. Les autres se rattachent par media_id.
const resolvedItems = `
	WITH resolved AS (
		SELECT i.id, i.list_id, i.media_type, i.tmdb_id, i.title, i.poster_url,
			i.release_date, i.added_at,
			CASE WHEN i.tmdb_id > 0
				THEN COALESCE((SELECT MIN(m.id) FROM medias m
					WHERE m.tmdb_id = i.tmdb_id AND m.type = i.media_type), 0)
				ELSE COALESCE(i.media_id, 0)
			END AS resolved_id
		FROM watch_list_items i
		WHERE i.list_id IN (%s)
	)`

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

func intArgs(ids []int) []interface{} {
	args := make([]interface{}, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return args
}

func scanList(row interface{ Scan(...interface{}) error }, viewerID int) (models.WatchList, error) {
	var l models.WatchList
	var updated int64
	if err := row.Scan(&l.ID, &l.Kind, &l.Name, &l.Description, &l.IsShared,
		&l.Owner.ID, &l.Owner.Username, &updated); err != nil {
		return models.WatchList{}, err
	}
	l.IsMine = l.Owner.ID == viewerID
	l.UpdatedAt = time.UnixMilli(updated).UTC()
	l.Posters = []string{}
	return l, nil
}

func (s *Store) queryLists(viewerID int, query string, args ...interface{}) ([]models.WatchList, error) {
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query watch lists: %w", err)
	}
	defer rows.Close()
	lists := []models.WatchList{}
	for rows.Next() {
		l, err := scanList(rows, viewerID)
		if err != nil {
			return nil, fmt.Errorf("scan watch list: %w", err)
		}
		lists = append(lists, l)
	}
	return lists, rows.Err()
}

// Lists renvoie les listes du compte, « à regarder plus tard » en tête, et
// celles que les autres comptes partagent. Avec probe, chacune des listes du
// compte dit si elle contient déjà ce titre.
func (s *Store) Lists(viewerID int, probe *Probe) (models.WatchListsResponse, error) {
	if err := s.EnsureWatchLater(viewerID); err != nil {
		return models.WatchListsResponse{}, err
	}
	mine, err := s.queryLists(viewerID, `
		SELECT `+listColumns+`
		FROM watch_lists w LEFT JOIN users u ON u.id = w.owner_id
		WHERE w.owner_id = ?
		ORDER BY w.kind = 'watch_later' DESC, w.updated_at DESC, w.id DESC`, viewerID)
	if err != nil {
		return models.WatchListsResponse{}, err
	}
	shared, err := s.queryLists(viewerID, `
		SELECT `+listColumns+`
		FROM watch_lists w LEFT JOIN users u ON u.id = w.owner_id
		WHERE w.is_shared = 1 AND w.owner_id <> ?
		ORDER BY w.updated_at DESC, w.id DESC
		LIMIT ?`, viewerID, maxSharedLists)
	if err != nil {
		return models.WatchListsResponse{}, err
	}
	if err := s.decorate(mine, shared); err != nil {
		return models.WatchListsResponse{}, err
	}
	if probe != nil {
		if err := s.markContains(mine, *probe); err != nil {
			return models.WatchListsResponse{}, err
		}
	}
	return models.WatchListsResponse{Mine: mine, Shared: shared}, nil
}

// summary relit une seule liste du compte, telle que Lists la rendrait.
func (s *Store) summary(viewerID, listID int) (models.WatchList, error) {
	l, err := scanList(s.db.QueryRow(`
		SELECT `+listColumns+`
		FROM watch_lists w LEFT JOIN users u ON u.id = w.owner_id
		WHERE w.id = ?`, listID), viewerID)
	if errors.Is(err, sql.ErrNoRows) {
		return models.WatchList{}, ErrNotFound
	}
	if err != nil {
		return models.WatchList{}, fmt.Errorf("load watch list: %w", err)
	}
	lists := []models.WatchList{l}
	if err := s.decorate(lists); err != nil {
		return models.WatchList{}, err
	}
	return lists[0], nil
}

// decorate remplit le nombre d'éléments et les affiches des listes, en deux
// requêtes pour toutes plutôt que deux par liste.
func (s *Store) decorate(groups ...[]models.WatchList) error {
	var ids []int
	for _, group := range groups {
		for _, l := range group {
			ids = append(ids, l.ID)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	counts := map[int]int{}
	rows, err := s.db.Query(fmt.Sprintf(`
		SELECT list_id, COUNT(*) FROM watch_list_items
		WHERE list_id IN (%s) GROUP BY list_id`, placeholders(len(ids))), intArgs(ids)...)
	if err != nil {
		return fmt.Errorf("count watch list items: %w", err)
	}
	for rows.Next() {
		var id, n int
		if err := rows.Scan(&id, &n); err != nil {
			rows.Close()
			return fmt.Errorf("scan watch list count: %w", err)
		}
		counts[id] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("count watch list items: %w", err)
	}

	posters := map[int][]string{}
	rows, err = s.db.Query(fmt.Sprintf(resolvedItems+`
		SELECT list_id, poster FROM (
			SELECT r.list_id, COALESCE(NULLIF(m.poster_url, ''), r.poster_url) AS poster,
				ROW_NUMBER() OVER (PARTITION BY r.list_id ORDER BY r.added_at DESC, r.id DESC) AS rank
			FROM resolved r LEFT JOIN medias m ON m.id = r.resolved_id
			WHERE COALESCE(NULLIF(m.poster_url, ''), r.poster_url) <> ''
		)
		WHERE rank <= ?
		ORDER BY list_id, rank`, placeholders(len(ids))), append(intArgs(ids), postersPerList)...)
	if err != nil {
		return fmt.Errorf("load watch list posters: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int
		var poster string
		if err := rows.Scan(&id, &poster); err != nil {
			return fmt.Errorf("scan watch list poster: %w", err)
		}
		posters[id] = append(posters[id], poster)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("load watch list posters: %w", err)
	}

	for _, group := range groups {
		for i := range group {
			group[i].ItemCount = counts[group[i].ID]
			if p := posters[group[i].ID]; p != nil {
				group[i].Posters = p
			}
		}
	}
	return nil
}

// Get renvoie une liste et ses éléments, du plus récent ajout au plus ancien.
// Chaque élément dit à quelle fiche du serveur il se rattache (MediaID) ; le
// handler y joint la fiche.
func (s *Store) Get(viewerID, listID int) (models.WatchListDetail, error) {
	l, err := s.summary(viewerID, listID)
	if err != nil {
		return models.WatchListDetail{}, err
	}
	if !l.IsMine && !l.IsShared {
		return models.WatchListDetail{}, ErrNotFound
	}
	items, err := s.items(s.db, listID, 0)
	if err != nil {
		return models.WatchListDetail{}, err
	}
	return models.WatchListDetail{WatchList: l, Items: items}, nil
}

// items lit les éléments d'une liste, ou le seul itemID s'il est donné.
func (s *Store) items(q querier, listID, itemID int) ([]models.WatchListItem, error) {
	query := fmt.Sprintf(resolvedItems, "?") + `
		SELECT id, media_type, tmdb_id, title, poster_url, release_date, added_at, resolved_id
		FROM resolved`
	args := []interface{}{listID}
	if itemID > 0 {
		query += ` WHERE id = ?`
		args = append(args, itemID)
	}
	query += ` ORDER BY added_at DESC, id DESC`
	rows, err := q.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query watch list items: %w", err)
	}
	defer rows.Close()
	items := []models.WatchListItem{}
	for rows.Next() {
		var it models.WatchListItem
		var added int64
		if err := rows.Scan(&it.ID, &it.MediaType, &it.TMDBID, &it.Title, &it.PosterURL,
			&it.ReleaseDate, &added, &it.MediaID); err != nil {
			return nil, fmt.Errorf("scan watch list item: %w", err)
		}
		it.AddedAt = time.UnixMilli(added).UTC()
		items = append(items, it)
	}
	return items, rows.Err()
}
