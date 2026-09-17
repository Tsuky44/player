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

	"github.com/julienschmidt/httprouter"
)

// Synchronisation de la progression avec Emby.
//
// Chaque utilisateur peut lier son compte Emby. La progression circule alors
// dans les deux sens, reconnue par identité de contenu (TMDB, saison, épisode)
// comme entre serveurs liés :
//   - Emby → Onyx : les médias en cours et vus sur Emby sont importés, le plus
//     récent l'emportant (importPortableProgress) ;
//   - Onyx → Emby : ce qui change ici (progress_changes) est envoyé à Emby, sauf
//     si Emby est déjà au même point ou plus récent — ce qui empêche aussi
//     l'import de revenir en écho.
//
// Le mot de passe ne sert qu'à obtenir un jeton ; seul le jeton est gardé.

const (
	embyTick       = 30 * time.Second
	embyPullEvery  = 10 * time.Minute
	embyIndexTTL   = 30 * time.Minute
	embyPage       = 500
	embyIDsChunk   = 100
	ticksPerSecond = 10_000_000

	// Deux positions à moins de cet écart sont considérées identiques.
	embyPositionSlack = 10 * ticksPerSecond
)

var embyHTTP = &http.Client{Timeout: 30 * time.Second}

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
		return fmt.Errorf("Emby injoignable : %w", err)
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

// ==================== EMBY → ONYX ====================

func embyPortable(item embyItem, idx *embyIndex) (PortableProgress, bool) {
	ud := item.UserData
	if ud == nil || (!ud.Played && ud.PlaybackPositionTicks <= 0) {
		return PortableProgress{}, false
	}
	position := ud.PlaybackPositionTicks
	if position <= 0 && ud.Played {
		position = item.RunTimeTicks
	}
	stamp := parseEmbyDate(ud.LastPlayedDate)
	if stamp.IsZero() {
		// Vu sans date : le plus ancien possible, pour ne combler qu'un vide.
		stamp = embyDateZero
	}
	e := PortableProgress{
		Position:  int(position / ticksPerSecond),
		Finished:  ud.Played,
		UpdatedAt: stamp.Format(time.RFC3339Nano),
	}
	switch item.Type {
	case "Movie":
		e.Type = "movie"
		e.TMDBID = providerTMDB(item.ProviderIds)
	case "Episode":
		if item.ParentIndexNumber == nil || item.IndexNumber == nil {
			return e, false
		}
		e.Type = "episode"
		e.TMDBID = idx.seriesTMDB[item.SeriesID]
		e.Season = *item.ParentIndexNumber
		e.Episode = *item.IndexNumber
	default:
		return e, false
	}
	return e, validatePortableProgress([]PortableProgress{e}) == ""
}

// pull importe ce qu'Emby sait et renvoie le nombre de progressions modifiées ici.
func (l embyLink) pull(ctx context.Context, idx *embyIndex) (int, error) {
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items"
	seen := map[string]bool{}
	var entries []PortableProgress
	for _, filter := range []string{"IsResumable", "IsPlayed"} {
		query := embyLibraryQuery("Movie,Episode")
		query.Set("Filters", filter)
		query.Set("EnableUserData", "true")
		items, err := l.items(ctx, path, query)
		if err != nil {
			return 0, err
		}
		for _, item := range items {
			if seen[item.ID] {
				continue
			}
			seen[item.ID] = true
			if e, ok := embyPortable(item, idx); ok {
				entries = append(entries, e)
			}
		}
	}
	var before int
	_ = database.DB.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM progress_changes`).Scan(&before)
	for start := 0; start < len(entries); start += federationBatch {
		end := min(start+federationBatch, len(entries))
		if err := importPortableProgress(l.userID, entries[start:end]); err != nil {
			return 0, err
		}
	}
	var changed int
	_ = database.DB.QueryRow(`SELECT COUNT(*) FROM progress_changes WHERE user_id = ? AND seq > ?`, l.userID, before).Scan(&changed)
	return changed, nil
}

// ==================== ONYX → EMBY ====================

// embyNeedsPush dit si Emby doit recevoir cette progression : il n'est pas
// déjà au même point, et ce qu'il sait n'est pas plus récent.
func embyNeedsPush(e PortableProgress, item embyItem) bool {
	ud := embyUserData{}
	if item.UserData != nil {
		ud = *item.UserData
	}
	if e.Finished {
		if ud.Played {
			return false
		}
	} else if !ud.Played {
		diff := ud.PlaybackPositionTicks - int64(e.Position)*ticksPerSecond
		if diff > -embyPositionSlack && diff < embyPositionSlack {
			return false
		}
	}
	local, err := time.Parse(time.RFC3339Nano, e.UpdatedAt)
	if err != nil {
		return false
	}
	remote := parseEmbyDate(ud.LastPlayedDate)
	return remote.IsZero() || local.After(remote.Add(time.Second))
}

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

// push envoie à Emby les progressions changées ici et renvoie le nombre envoyé.
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
			e := targets[id]
			item, ok := current[id]
			if !ok || !embyNeedsPush(e, item) {
				continue
			}
			stamp, _ := time.Parse(time.RFC3339Nano, e.UpdatedAt)
			ticks := int64(e.Position) * ticksPerSecond
			if e.Finished {
				ticks = 0
			}
			body := map[string]any{
				"PlaybackPositionTicks": ticks,
				"Played":                e.Finished,
				"LastPlayedDate":        stamp.UTC().Format("2006-01-02T15:04:05.0000000Z"),
			}
			path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items/" + url.PathEscape(id) + "/UserData"
			if err := l.call(ctx, http.MethodPost, path, nil, body, nil); err != nil {
				return pushed, err
			}
			pushed++
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
	var deviceID string
	_ = database.DB.QueryRow(`SELECT device_id FROM emby_links WHERE user_id = ?`, userID).Scan(&deviceID)
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
