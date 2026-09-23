package handlers

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/httpx"

	"github.com/julienschmidt/httprouter"
)

// Synchronisation de la progression avec Emby.
//
// Chaque utilisateur peut lier son compte Emby. La progression circule alors
// dans les deux sens, reconnue par identité de contenu (TMDB, saison, épisode)
// comme entre serveurs liés. Trois moments la font circuler :
//   - Emby est relu en entier toutes les dix minutes ;
//   - ce qui change ici (progress_changes) part vers Emby dans les trente
//     secondes ;
//   - juste avant de donner un point de reprise, Onyx redemande à Emby où en
//     est ce média-là (refreshEmbyMedia).
//
// À chaque fois, c'est la même décision (decideEmby) : la dernière lecture
// gagne, reconnue au côté qui s'est écarté du dernier accord (emby_baselines),
// pas à des dates que les deux serveurs ne donnent pas dans le même sens.
//
// Le mot de passe ne sert qu'à obtenir un jeton ; seul le jeton est gardé.

const (
	embyTick       = 30 * time.Second
	embyPullEvery  = 10 * time.Minute
	embyIndexTTL   = 30 * time.Minute
	embyPage       = 500
	embyIDsChunk   = 100
	ticksPerSecond = 10_000_000
)

// embyHTTP ne se connecte qu'à des adresses permises : l'URL vient de
// l'utilisateur. Voir httpx.UserDirected.
var embyHTTP = httpx.UserDirected

// embySyncMu sérialise les synchronisations : la tâche de fond et le bouton
// « Synchroniser » ne travaillent jamais en même temps, et les caches
// ci-dessous ne sont lus et écrits que sous ce verrou.
var (
	embySyncMu   sync.Mutex
	embyIndexes  = map[string]*embyIndex{}
	embyLastPull = map[string]time.Time{}
	embyBackoffs = map[string]*peerBackoff{} // par jeton : relier repart à zéro
	embyWake     = make(chan struct{}, 1)
	errEmbyAuth  = errors.New("Emby a refusé la session : reconnectez le compte")
	embyDateZero = time.Unix(0, 0).UTC()
)

type embyLink struct {
	userID     int
	url        string
	embyUserID string
	username   string
	token      string
	deviceID   string
	pushedSeq  int
}

func (l embyLink) cacheKey() string { return l.url + "|" + l.embyUserID }

type embyUserData struct {
	PlaybackPositionTicks int64  `json:"PlaybackPositionTicks"`
	Played                bool   `json:"Played"`
	LastPlayedDate        string `json:"LastPlayedDate,omitempty"`
}

type embyItem struct {
	ID                string            `json:"Id"`
	Type              string            `json:"Type"`
	SeriesID          string            `json:"SeriesId"`
	ParentIndexNumber *int              `json:"ParentIndexNumber"`
	IndexNumber       *int              `json:"IndexNumber"`
	RunTimeTicks      int64             `json:"RunTimeTicks"`
	ProviderIds       map[string]string `json:"ProviderIds"`
	UserData          *embyUserData     `json:"UserData"`
}

type embyItemsPage struct {
	Items            []embyItem `json:"Items"`
	TotalRecordCount int        `json:"TotalRecordCount"`
}

// embyIndex relie les identités TMDB aux éléments de la bibliothèque Emby.
type embyIndex struct {
	builtAt    time.Time
	movies     map[int]string
	series     map[int]string
	seriesTMDB map[string]int
	episodes   map[string]map[[2]int]string
}

type embyStatusError struct {
	status int
	msg    string
}

func (e *embyStatusError) Error() string { return e.msg }

// ==================== CLIENT EMBY ====================

func embyAuthorization(deviceID string) string {
	return fmt.Sprintf(`Emby Client="Onyx", Device="Onyx Server", DeviceId="%s", Version="1.0.0"`, deviceID)
}

func embyRequest(ctx context.Context, base, token, deviceID, method, path string, query url.Values, body, out any) error {
	target := base + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Emby-Authorization", embyAuthorization(deviceID))
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("X-Emby-Token", token)
	}
	resp, err := embyHTTP.Do(req)
	if err != nil {
		// Le détail reste dans le journal. Renvoyé à l'appelant, il disait si
		// une adresse du réseau interne refuse la connexion ou ne répond pas —
		// de quoi cartographier ce réseau depuis n'importe quel compte.
		log.Printf("Emby: %s %s: %v", method, base, err)
		return errors.New("Emby injoignable à cette adresse")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return &embyStatusError{resp.StatusCode, errEmbyAuth.Error()}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &embyStatusError{resp.StatusCode, fmt.Sprintf("Emby a répondu %d sur %s", resp.StatusCode, path)}
	}
	if out == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("Réponse Emby illisible : %w", err)
	}
	return nil
}

func (l embyLink) call(ctx context.Context, method, path string, query url.Values, body, out any) error {
	return embyRequest(ctx, l.url, l.token, l.deviceID, method, path, query, body, out)
}

func isEmbyAuthError(err error) bool {
	var status *embyStatusError
	return errors.As(err, &status) && (status.status == http.StatusUnauthorized || status.status == http.StatusForbidden)
}

type embyAuthResult struct {
	AccessToken string `json:"AccessToken"`
	User        struct {
		ID   string `json:"Id"`
		Name string `json:"Name"`
	} `json:"User"`
}

func embyAuthenticate(ctx context.Context, base, deviceID, username, password string) (embyAuthResult, error) {
	var result embyAuthResult
	err := embyRequest(ctx, base, "", deviceID, http.MethodPost, "/Users/AuthenticateByName", nil,
		map[string]string{"Username": username, "Pw": password}, &result)
	if isEmbyAuthError(err) {
		return result, errors.New("Nom d’utilisateur ou mot de passe Emby incorrect")
	}
	if err != nil {
		return result, err
	}
	if result.AccessToken == "" || result.User.ID == "" {
		return result, errors.New("Ce serveur ne ressemble pas à un serveur Emby")
	}
	return result, nil
}

// embyItems lit toutes les pages d'une requête sur la bibliothèque de l'utilisateur.
func (l embyLink) items(ctx context.Context, path string, query url.Values) ([]embyItem, error) {
	var all []embyItem
	for start := 0; ; start += embyPage {
		query.Set("StartIndex", strconv.Itoa(start))
		query.Set("Limit", strconv.Itoa(embyPage))
		var page embyItemsPage
		if err := l.call(ctx, http.MethodGet, path, query, nil, &page); err != nil {
			return nil, err
		}
		all = append(all, page.Items...)
		if len(page.Items) < embyPage || len(all) >= page.TotalRecordCount {
			return all, nil
		}
	}
}

func embyLibraryQuery(types string) url.Values {
	return url.Values{
		"Recursive":        {"true"},
		"IncludeItemTypes": {types},
		"Fields":           {"ProviderIds"},
		"EnableImages":     {"false"},
	}
}

func providerTMDB(ids map[string]string) int {
	for key, value := range ids {
		if strings.EqualFold(key, "tmdb") {
			if id, err := strconv.Atoi(strings.TrimSpace(value)); err == nil && id > 0 {
				return id
			}
		}
	}
	return 0
}

func parseEmbyDate(raw string) time.Time {
	if raw == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil || t.Year() < 1971 {
		return time.Time{}
	}
	return t.UTC()
}

// ==================== INDEX ====================

func (l embyLink) buildIndex(ctx context.Context) (*embyIndex, error) {
	idx := &embyIndex{
		builtAt:    time.Now(),
		movies:     map[int]string{},
		series:     map[int]string{},
		seriesTMDB: map[string]int{},
		episodes:   map[string]map[[2]int]string{},
	}
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items"
	movies, err := l.items(ctx, path, embyLibraryQuery("Movie"))
	if err != nil {
		return nil, err
	}
	for _, m := range movies {
		if tmdb := providerTMDB(m.ProviderIds); tmdb > 0 {
			idx.movies[tmdb] = m.ID
		}
	}
	shows, err := l.items(ctx, path, embyLibraryQuery("Series"))
	if err != nil {
		return nil, err
	}
	for _, s := range shows {
		if tmdb := providerTMDB(s.ProviderIds); tmdb > 0 {
			idx.series[tmdb] = s.ID
			idx.seriesTMDB[s.ID] = tmdb
		}
	}
	return idx, nil
}

func (l embyLink) episodeIndex(ctx context.Context, idx *embyIndex, seriesID string) (map[[2]int]string, error) {
	if eps, ok := idx.episodes[seriesID]; ok {
		return eps, nil
	}
	query := url.Values{
		"UserId":         {l.embyUserID},
		"EnableImages":   {"false"},
		"EnableUserData": {"false"},
	}
	items, err := l.items(ctx, "/Shows/"+url.PathEscape(seriesID)+"/Episodes", query)
	if err != nil {
		return nil, err
	}
	eps := map[[2]int]string{}
	for _, e := range items {
		if e.ParentIndexNumber != nil && e.IndexNumber != nil {
			eps[[2]int{*e.ParentIndexNumber, *e.IndexNumber}] = e.ID
		}
	}
	idx.episodes[seriesID] = eps
	return eps, nil
}

func (l embyLink) resolve(ctx context.Context, idx *embyIndex, e PortableProgress) (string, error) {
	if e.Type == "movie" {
		return idx.movies[e.TMDBID], nil
	}
	seriesID := idx.series[e.TMDBID]
	if seriesID == "" {
		return "", nil
	}
	eps, err := l.episodeIndex(ctx, idx, seriesID)
	if err != nil {
		return "", err
	}
	return eps[[2]int{e.Season, e.Episode}], nil
}

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

// ==================== AU MOMENT DE REPRENDRE ====================

// embyRefreshTimeout borne ce que la reprise d'une lecture peut attendre
// d'Emby. Au-delà, Onyx reprend avec ce qu'il sait.
const embyRefreshTimeout = 2 * time.Second

// refreshEmbyMedia tranche un seul média avec Emby, juste avant qu'Onyx donne
// son point de reprise.
//
// Emby n'est relu en entier que toutes les dix minutes. Sans ce rafraîchissement,
// passer d'Emby à Onyx dans l'intervalle faisait reprendre Onyx à son ancienne
// position — et son premier battement, daté de maintenant, renvoyait cette
// position périmée sur Emby. C'est le moment exact où la bonne réponse compte.
//
// Jamais bloquant : sans index déjà construit, avec une synchronisation en
// cours, ou au-delà du délai, Onyx répond avec ce qu'il a.
func refreshEmbyMedia(parent context.Context, userID, mediaID int) {
	if !embySyncMu.TryLock() {
		return
	}
	defer embySyncMu.Unlock()

	link, err := scanEmbyLink(database.DB.QueryRow(`SELECT `+embyLinkColumns+` FROM emby_links WHERE user_id = ?`, userID))
	if err != nil {
		return
	}
	// Un Emby qui vient d'échouer ne fait pas attendre chaque ouverture de fiche :
	// la tâche de fond réessaiera à son rythme.
	if b := embyBackoffs[link.token]; b != nil && time.Now().Before(b.retryAt) {
		return
	}
	idx := embyIndexes[link.cacheKey()]
	if idx == nil {
		return
	}
	var k contentKey
	err = database.DB.QueryRow(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
		SELECT type, tmdb, season, episode FROM content WHERE id = ?`, mediaID).
		Scan(&k.Type, &k.TMDBID, &k.Season, &k.Episode)
	if err != nil {
		return // pas d'identité portable : rien à demander à Emby
	}

	ctx, cancel := context.WithTimeout(parent, embyRefreshTimeout)
	defer cancel()
	probe := PortableProgress{Type: k.Type, TMDBID: k.TMDBID, Season: k.Season, Episode: k.Episode}
	itemID, err := link.resolve(ctx, idx, probe)
	if err != nil || itemID == "" {
		return
	}
	current, err := link.userData(ctx, []string{itemID})
	if err != nil {
		return
	}
	item, ok := current[itemID]
	if !ok {
		return
	}
	locals, err := loadLocalProgress(userID, strconv.Itoa(mediaID))
	if err != nil {
		return
	}
	var local *localSide
	if side, found := locals[k]; found {
		local = &side
	}
	base, err := loadEmbyBaseline(userID, k)
	if err != nil {
		return
	}
	if _, err := link.reconcile(ctx, k, itemID, item, local, base); err != nil {
		log.Printf("Emby refresh (user %d, media %d): %v", userID, mediaID, err)
	}
}

// ==================== SYNCHRONISATION ====================

type embySyncResult struct {
	Pulled int `json:"pulled"`
	Pushed int `json:"pushed"`
}

// syncEmby fait une passe complète pour un compte. full force la relecture de
// la bibliothèque et de la progression Emby. À appeler sous embySyncMu.
func syncEmby(ctx context.Context, link *embyLink, full bool) (embySyncResult, error) {
	var result embySyncResult
	key := link.cacheKey()
	idx := embyIndexes[key]
	if full || idx == nil || time.Since(idx.builtAt) > embyIndexTTL {
		built, err := link.buildIndex(ctx)
		if err != nil {
			return result, embySyncFailed(link, err)
		}
		idx = built
		embyIndexes[key] = idx
	}
	if full || time.Since(embyLastPull[key]) > embyPullEvery {
		pulled, err := link.pull(ctx, idx)
		if err != nil {
			return result, embySyncFailed(link, err)
		}
		result.Pulled = pulled
		embyLastPull[key] = time.Now()
	}
	pushed, err := link.push(ctx, idx)
	result.Pushed = pushed
	if err != nil {
		return result, embySyncFailed(link, err)
	}
	delete(embyBackoffs, link.token)
	_, _ = database.DB.Exec(`UPDATE emby_links SET last_error = '', last_sync_at = ? WHERE user_id = ?`,
		time.Now().UTC().Format(progressTimeLayout), link.userID)
	return result, nil
}

func embySyncFailed(link *embyLink, err error) error {
	b := embyBackoffs[link.token]
	if b == nil {
		b = &peerBackoff{}
		embyBackoffs[link.token] = b
	}
	b.failures++
	b.retryAt = time.Now().Add(embyTick << min(b.failures, 5)) // jusqu'à ~16 min
	_, _ = database.DB.Exec(`UPDATE emby_links SET last_error = ? WHERE user_id = ?`, err.Error(), link.userID)
	return err
}

const embyLinkColumns = `user_id, url, emby_user_id, emby_username, access_token, device_id, pushed_seq`

func scanEmbyLink(row rowScanner) (embyLink, error) {
	var l embyLink
	err := row.Scan(&l.userID, &l.url, &l.embyUserID, &l.username, &l.token, &l.deviceID, &l.pushedSeq)
	return l, err
}

func wakeEmbySync() {
	select {
	case embyWake <- struct{}{}:
	default:
	}
}

// RunEmbySync synchronise en tâche de fond les comptes Emby liés jusqu'à
// l'arrêt du contexte : envoi de ce qui change ici toutes les 30 secondes,
// relecture d'Emby toutes les 10 minutes.
func RunEmbySync(ctx context.Context) {
	ticker := time.NewTicker(embyTick)
	defer ticker.Stop()
	for {
		embyPass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-embyWake:
		}
	}
}

func embyPass(ctx context.Context) {
	if database.DB == nil {
		return
	}
	rows, err := database.DB.Query(`SELECT ` + embyLinkColumns + ` FROM emby_links`)
	if err != nil {
		return
	}
	var links []embyLink
	for rows.Next() {
		if l, err := scanEmbyLink(rows); err == nil {
			links = append(links, l)
		}
	}
	rows.Close()

	embySyncMu.Lock()
	defer embySyncMu.Unlock()
	now := time.Now()
	for i := range links {
		link := &links[i]
		if ctx.Err() != nil {
			return
		}
		if b := embyBackoffs[link.token]; b != nil && now.Before(b.retryAt) {
			continue
		}
		pullDue := time.Since(embyLastPull[link.cacheKey()]) > embyPullEvery
		if !pullDue {
			var pending bool
			_ = database.DB.QueryRow(`SELECT EXISTS (SELECT 1 FROM progress_changes WHERE user_id = ? AND seq > ?)`,
				link.userID, link.pushedSeq).Scan(&pending)
			if !pending {
				continue
			}
		}
		passCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		if _, err := syncEmby(passCtx, link, false); err != nil {
			log.Printf("Emby sync (user %d): %v", link.userID, err)
		}
		cancel()
	}
}

// ==================== API ====================

type embyLinkStatus struct {
	Linked     bool       `json:"linked"`
	URL        string     `json:"url,omitempty"`
	Username   string     `json:"username,omitempty"`
	LastSyncAt *time.Time `json:"last_sync_at,omitempty"`
	LastError  string     `json:"last_error,omitempty"`
}

func loadEmbyStatus(userID int) (embyLinkStatus, error) {
	var status embyLinkStatus
	var stamp sql.NullString
	err := database.DB.QueryRow(`SELECT url, emby_username, last_sync_at, last_error FROM emby_links WHERE user_id = ?`, userID).
		Scan(&status.URL, &status.Username, &stamp, &status.LastError)
	if err == sql.ErrNoRows {
		return embyLinkStatus{}, nil
	}
	if err != nil {
		return status, err
	}
	status.Linked = true
	if date := scanSQLiteTime(stamp); !date.IsZero() {
		status.LastSyncAt = &date
	}
	return status, nil
}

func writeEmbyStatus(w http.ResponseWriter, userID int) {
	status, err := loadEmbyStatus(userID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Impossible de lire le lien Emby")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

// GetEmbyLink renvoie l'état du lien Emby du compte (GET /api/me/emby).
func GetEmbyLink(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	writeEmbyStatus(w, userID)
}

type embyLinkRequest struct {
	URL      string `json:"url"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// LinkEmby connecte le compte à Emby (PUT /api/me/emby).
func LinkEmby(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var body embyLinkRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	base, ok := normalizeServerURL(body.URL)
	username := strings.TrimSpace(body.Username)
	if !ok || username == "" {
		writeJSONError(w, http.StatusBadRequest, "Adresse Emby et nom d’utilisateur requis")
		return
	}
	var deviceID, previousURL, previousEmbyUser string
	_ = database.DB.QueryRow(`SELECT device_id, url, emby_user_id FROM emby_links WHERE user_id = ?`, userID).
		Scan(&deviceID, &previousURL, &previousEmbyUser)
	if deviceID == "" {
		token, err := GenerateRandomToken()
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "Impossible de créer l’appareil")
			return
		}
		deviceID = "onyx-" + token[:24]
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	auth, err := embyAuthenticate(ctx, base, deviceID, username, body.Password)
	if err != nil {
		writeJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	// Un nouveau lien renvoie tout l'historique : l'envoi ne réécrit rien
	// qu'Emby sait déjà.
	_, err = database.DB.Exec(`INSERT INTO emby_links (user_id, url, emby_user_id, emby_username, access_token, device_id)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET url = excluded.url, emby_user_id = excluded.emby_user_id,
			emby_username = excluded.emby_username, access_token = excluded.access_token,
			device_id = excluded.device_id, pushed_seq = 0, last_error = '', last_sync_at = NULL`,
		userID, base, auth.User.ID, auth.User.Name, auth.AccessToken, deviceID)
	if err != nil {
		log.Printf("LinkEmby: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Impossible d’enregistrer le lien Emby")
		return
	}
	// Un autre compte, ou un autre serveur : les accords retenus parlaient d'une
	// autre progression. Se reconnecter au même compte les garde.
	if previousURL != base || previousEmbyUser != auth.User.ID {
		_, _ = database.DB.Exec(`DELETE FROM emby_baselines WHERE user_id = ?`, userID)
	}
	wakeEmbySync()
	writeEmbyStatus(w, userID)
}

// UnlinkEmby retire le lien et ferme la session ouverte sur Emby (DELETE /api/me/emby).
func UnlinkEmby(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	link, err := scanEmbyLink(database.DB.QueryRow(`SELECT `+embyLinkColumns+` FROM emby_links WHERE user_id = ?`, userID))
	if err == nil {
		if _, err := database.DB.Exec(`DELETE FROM emby_links WHERE user_id = ?`, userID); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "Impossible de retirer le lien Emby")
			return
		}
		_, _ = database.DB.Exec(`DELETE FROM emby_baselines WHERE user_id = ?`, userID)
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = link.call(ctx, http.MethodPost, "/Sessions/Logout", nil, nil, nil)
		}()
	}
	writeEmbyStatus(w, userID)
}

// SyncEmbyNow relit Emby et envoie ce qui a changé, sans attendre la tâche de
// fond (POST /api/me/emby/sync).
func SyncEmbyNow(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	link, err := scanEmbyLink(database.DB.QueryRow(`SELECT `+embyLinkColumns+` FROM emby_links WHERE user_id = ?`, userID))
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusNotFound, "Aucun compte Emby lié")
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Impossible de lire le lien Emby")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	embySyncMu.Lock()
	result, err := syncEmby(ctx, &link, true)
	embySyncMu.Unlock()
	if err != nil {
		writeJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}
