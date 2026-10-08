package handlers

import (
	"context"
	"database/sql"
	"net/http"
	"net/url"
	"project-player/server/database"
	"strings"
	"time"
)

// La décision entre Onyx et Emby, et son application dans les deux sens.
// Voir emby_sync.go.

// ==================== DÉCISION ====================

// progressState est ce que les deux côtés comparent : où l'on en est, et si
// c'est vu. Les dates n'en font pas partie.
type progressState struct {
	Position int
	Finished bool
}

// Deux positions à moins de cet écart sont le même endroit : les deux côtés
// n'arrondissent pas pareil, et un battement de plus ne fait pas un désaccord.
const embyPositionSlackSeconds = 10

func (s progressState) empty() bool { return !s.Finished && s.Position <= 0 }

func (s progressState) matches(o progressState) bool {
	if s.Finished != o.Finished {
		return false
	}
	if s.Finished {
		return true
	}
	d := s.Position - o.Position
	return d > -embyPositionSlackSeconds && d < embyPositionSlackSeconds
}

// contentKey est l'identité portable d'un contenu, la seule que les deux côtés
// partagent.
type contentKey struct {
	Type    string
	TMDBID  int
	Season  int
	Episode int
}

func keyOf(e PortableProgress) contentKey {
	return contentKey{e.Type, e.TMDBID, e.Season, e.Episode}
}

type embyVerdict int

const (
	// Les deux côtés disent la même chose : rien à écrire, l'accord est retenu.
	embyInSync embyVerdict = iota
	// Emby a la dernière lecture : elle s'écrit ici.
	embyWins
	// Onyx a la dernière lecture : elle part vers Emby.
	onyxWins
)

// decideEmby dit quel côté a la dernière lecture.
//
// base est le dernier état sur lequel les deux étaient d'accord (nil tant
// qu'aucun ne l'a été). Quand un seul côté s'en est écarté, c'est lui qui a
// bougé, donc lui qui a raison — sans regarder aucune date. C'est ce qui rend la
// décision juste : le LastPlayedDate d'Emby est l'heure du *début* de sa
// dernière lecture, pas de sa dernière modification. Une heure de film sur
// Emby garde la date de la première seconde, et la comparer à la dernière
// modification ici donnait régulièrement la victoire au côté qui n'avait pas
// bougé.
//
// Les dates ne départagent que ce que l'accord ne peut pas : les deux côtés ont
// bougé depuis, ou il n'y a encore jamais eu d'accord.
//
// Un côté vide n'efface jamais l'autre. Une progression absente ici veut dire
// « jamais regardé ici », et un élément Emby sans données peut être un média
// réimporté sous un nouvel identifiant : dans les deux cas, écraser une vraie
// progression par du vide serait une perte, pas une synchronisation.
func decideEmby(local, emby progressState, localAt, embyAt time.Time, base *progressState) embyVerdict {
	switch {
	case local.matches(emby):
		return embyInSync
	case emby.empty():
		return onyxWins
	case local.empty():
		return embyWins
	}
	if base != nil {
		localMoved := !local.matches(*base)
		embyMoved := !emby.matches(*base)
		switch {
		case embyMoved && !localMoved:
			return embyWins
		case localMoved && !embyMoved:
			return onyxWins
		}
	}
	if embyAt.After(localAt) {
		return embyWins
	}
	return onyxWins
}

// ==================== ÉTAT DE CHAQUE CÔTÉ ====================

// embyItemState lit l'état d'un élément Emby et la date qu'Emby lui donne.
func embyItemState(item embyItem) (progressState, time.Time) {
	ud := item.UserData
	if ud == nil {
		return progressState{}, time.Time{}
	}
	position := ud.PlaybackPositionTicks
	if position <= 0 && ud.Played {
		position = item.RunTimeTicks
	}
	return progressState{Position: int(position / ticksPerSecond), Finished: ud.Played},
		parseEmbyDate(ud.LastPlayedDate)
}

// embyItemKey donne l'identité portable d'un élément de la bibliothèque Emby.
func embyItemKey(item embyItem, idx *embyIndex) (contentKey, bool) {
	var key contentKey
	switch item.Type {
	case "Movie":
		key = contentKey{Type: "movie", TMDBID: providerTMDB(item.ProviderIds)}
	case "Episode":
		if item.ParentIndexNumber == nil || item.IndexNumber == nil {
			return key, false
		}
		key = contentKey{
			Type:    "episode",
			TMDBID:  idx.seriesTMDB[item.SeriesID],
			Season:  *item.ParentIndexNumber,
			Episode: *item.IndexNumber,
		}
	default:
		return key, false
	}
	probe := PortableProgress{Type: key.Type, TMDBID: key.TMDBID, Season: key.Season,
		Episode: key.Episode, UpdatedAt: embyDateZero.Format(time.RFC3339Nano)}
	return key, validatePortableProgress([]PortableProgress{probe}) == ""
}

// localSide est ce qu'Onyx sait d'un contenu.
type localSide struct {
	state progressState
	at    time.Time
}

func localSideOf(e PortableProgress) localSide {
	at, _ := time.Parse(time.RFC3339Nano, e.UpdatedAt)
	return localSide{progressState{e.Position, e.Finished}, at}
}

// loadLocalProgress lit la progression d'un compte, par contenu. mediaID
// restreint à un média ("" pour tous).
func loadLocalProgress(userID int, mediaID string) (map[contentKey]localSide, error) {
	entries, err := readPortableProgress(userID, mediaID)
	if err != nil {
		return nil, err
	}
	out := make(map[contentKey]localSide, len(entries))
	for _, e := range entries {
		out[keyOf(e)] = localSideOf(e)
	}
	return out, nil
}

// ==================== ACCORDS ====================

func loadEmbyBaselines(userID int) (map[contentKey]progressState, error) {
	rows, err := database.DB.Query(`SELECT type, tmdb_id, season, episode, position, finished
		FROM emby_baselines WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[contentKey]progressState{}
	for rows.Next() {
		var k contentKey
		var s progressState
		if err := rows.Scan(&k.Type, &k.TMDBID, &k.Season, &k.Episode, &s.Position, &s.Finished); err != nil {
			return nil, err
		}
		out[k] = s
	}
	return out, rows.Err()
}

func loadEmbyBaseline(userID int, k contentKey) (*progressState, error) {
	var s progressState
	err := database.DB.QueryRow(`SELECT position, finished FROM emby_baselines
		WHERE user_id = ? AND type = ? AND tmdb_id = ? AND season = ? AND episode = ?`,
		userID, k.Type, k.TMDBID, k.Season, k.Episode).Scan(&s.Position, &s.Finished)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func saveEmbyBaseline(userID int, k contentKey, s progressState) error {
	_, err := database.DB.Exec(`INSERT INTO emby_baselines
		(user_id, type, tmdb_id, season, episode, position, finished) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, type, tmdb_id, season, episode) DO UPDATE SET
			position = excluded.position, finished = excluded.finished`,
		userID, k.Type, k.TMDBID, k.Season, k.Episode, s.Position, s.Finished)
	return err
}

// ==================== APPLICATION ====================

// writeEmbyLocally écrit ici l'état qu'Emby a gagné, et dit si une ligne a
// été écrite.
//
// Sans la garde de date d'importPortableProgress : la décision est déjà prise,
// et la date d'Emby — un début de lecture — est justement celle qui la
// fausserait. La ligne est datée de maintenant, le moment où Onyx l'apprend.
func writeEmbyLocally(userID int, k contentKey, s progressState) (bool, error) {
	result, err := database.DB.Exec(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
		INSERT INTO progressions(user_id, media_id, current_position_seconds, is_finished, updated_at)
		SELECT ?, id, ?, ?, ? FROM content WHERE type = ? AND tmdb = ? AND season = ? AND episode = ?
		ON CONFLICT(user_id, media_id) DO UPDATE SET
			current_position_seconds = excluded.current_position_seconds,
			is_finished = excluded.is_finished, updated_at = excluded.updated_at`,
		userID, s.Position, s.Finished, time.Now().UTC().Format(progressTimeLayout),
		k.Type, k.TMDBID, k.Season, k.Episode)
	if err != nil {
		return false, err
	}
	// Zéro ligne : ce contenu n'est pas dans la bibliothèque d'Onyx.
	written, _ := result.RowsAffected()
	return written > 0, nil
}

// sendToEmby écrit sur Emby l'état qu'Onyx a gagné.
func (l embyLink) sendToEmby(ctx context.Context, itemID string, s progressState, at time.Time) error {
	ticks := int64(s.Position) * ticksPerSecond
	if s.Finished {
		ticks = 0
	}
	if at.IsZero() {
		at = time.Now()
	}
	body := map[string]any{
		"PlaybackPositionTicks": ticks,
		"Played":                s.Finished,
		// Pour l'ordre « récemment regardé » d'Emby, pas pour la décision.
		"LastPlayedDate": at.UTC().Format("2006-01-02T15:04:05.0000000Z"),
	}
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items/" + url.PathEscape(itemID) + "/UserData"
	return l.call(ctx, http.MethodPost, path, nil, body, nil)
}

// reconcile tranche un contenu et applique le verdict, accord compris.
// local vaut nil quand Onyx n'a rien sur ce contenu.
func (l embyLink) reconcile(ctx context.Context, k contentKey, itemID string, item embyItem,
	local *localSide, base *progressState) (embyVerdict, error) {
	embyState, embyAt := embyItemState(item)
	var here localSide
	if local != nil {
		here = *local
	}
	verdict := decideEmby(here.state, embyState, here.at, embyAt, base)

	agreed := here.state
	switch verdict {
	case embyWins:
		written, err := writeEmbyLocally(l.userID, k, embyState)
		if err != nil {
			return verdict, err
		}
		if !written {
			// Un contenu qu'Emby a et pas Onyx : rien ne s'est passé ici, et il
			// n'y a pas d'accord entre deux côtés dont un seul le connaît.
			return embyInSync, nil
		}
		agreed = embyState
	case onyxWins:
		if err := l.sendToEmby(ctx, itemID, here.state, here.at); err != nil {
			return verdict, err
		}
	}
	// Rien des deux côtés : il n'y a pas d'accord à retenir, seulement du vide.
	if agreed.empty() {
		return verdict, nil
	}
	if base == nil || !base.matches(agreed) {
		if err := saveEmbyBaseline(l.userID, k, agreed); err != nil {
			return verdict, err
		}
	}
	return verdict, nil
}

// ==================== EMBY → ONYX ====================

// pull relit ce qu'Emby sait et tranche chaque contenu. Renvoie le nombre de
// progressions écrites ici.
func (l embyLink) pull(ctx context.Context, idx *embyIndex) (int, error) {
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items"
	seen := map[string]bool{}
	var items []embyItem
	for _, filter := range []string{"IsResumable", "IsPlayed"} {
		query := embyLibraryQuery("Movie,Episode")
		query.Set("Filters", filter)
		query.Set("EnableUserData", "true")
		page, err := l.items(ctx, path, query)
		if err != nil {
			return 0, err
		}
		for _, item := range page {
			if !seen[item.ID] {
				seen[item.ID] = true
				items = append(items, item)
			}
		}
	}

	locals, err := loadLocalProgress(l.userID, "")
	if err != nil {
		return 0, err
	}
	bases, err := loadEmbyBaselines(l.userID)
	if err != nil {
		return 0, err
	}
	written := 0
	for _, item := range items {
		k, ok := embyItemKey(item, idx)
		if !ok {
			continue
		}
		var local *localSide
		if side, found := locals[k]; found {
			local = &side
		}
		var base *progressState
		if b, found := bases[k]; found {
			base = &b
		}
		verdict, err := l.reconcile(ctx, k, item.ID, item, local, base)
		if err != nil {
			return written, err
		}
		if verdict == embyWins {
			written++
		}
	}
	return written, nil
}

// ==================== ONYX → EMBY ====================

func (l embyLink) userData(ctx context.Context, ids []string) (map[string]embyItem, error) {
	out := map[string]embyItem{}
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items"
	for start := 0; start < len(ids); start += embyIDsChunk {
		end := min(start+embyIDsChunk, len(ids))
		query := url.Values{
			"Ids":            {strings.Join(ids[start:end], ",")},
			"EnableUserData": {"true"},
			"EnableImages":   {"false"},
		}
		var page embyItemsPage
		if err := l.call(ctx, http.MethodGet, path, query, nil, &page); err != nil {
			return nil, err
		}
		for _, item := range page.Items {
			out[item.ID] = item
		}
	}
	return out, nil
}

// push tranche chaque contenu qui a changé ici. Renvoie le nombre de
// progressions envoyées à Emby.
func (l *embyLink) push(ctx context.Context, idx *embyIndex) (int, error) {
	pushed := 0
	for {
		entries, lastSeq, read, err := pendingChanges(l.userID, l.pushedSeq)
		if err != nil || read == 0 {
			return pushed, err
		}
		targets := map[string]PortableProgress{}
		var ids []string
		for _, e := range entries {
			id, err := l.resolve(ctx, idx, e)
			if err != nil {
				return pushed, err
			}
			if id == "" {
				continue
			}
			if _, dup := targets[id]; !dup {
				ids = append(ids, id)
			}
			targets[id] = e
		}
		current, err := l.userData(ctx, ids)
		if err != nil {
			return pushed, err
		}
		for _, id := range ids {
			item, ok := current[id]
			if !ok {
				continue
			}
			e := targets[id]
			k := keyOf(e)
			local := localSideOf(e)
			base, err := loadEmbyBaseline(l.userID, k)
			if err != nil {
				return pushed, err
			}
			verdict, err := l.reconcile(ctx, k, id, item, &local, base)
			if err != nil {
				return pushed, err
			}
			if verdict == onyxWins {
				pushed++
			}
		}
		if _, err := database.DB.Exec(`UPDATE emby_links SET pushed_seq = ? WHERE user_id = ?`, lastSeq, l.userID); err != nil {
			return pushed, err
		}
		l.pushedSeq = lastSeq
		if read < federationBatch {
			return pushed, nil
		}
	}
}
