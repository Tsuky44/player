package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/safego"

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
			defer safego.Recover("handlers/emby_sync.go:1066")
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
