package handlers

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Séances « Regarder ensemble » : plusieurs appareils, pas forcément sur le
// même compte, lisent le même média au même endroit, et chacun peut mettre en
// pause, reprendre ou chercher pour tout le monde.
//
// Le serveur ne tient qu'un état de référence par séance — quel média, lecture
// ou pause, et la position à un instant donné — et le numérote. Chaque
// appareil l'attend en long-polling (GET …?since=N rend la main dès que le
// numéro dépasse N, ou au bout de [watchPartyPollWindow]) et se recale dessus.
// Pas de WebSocket : le long-polling passe par le même client HTTP que le
// reste de l'API, sur toutes les plateformes y compris le web et l'Apple TV,
// sans dépendance de plus d'un côté ni de l'autre.
//
// La position n'est jamais comparée entre horloges : le serveur calcule la
// position « maintenant » au moment où il répond, et l'appareil n'a plus qu'à
// y ajouter le temps écoulé depuis la réception. Aucune synchronisation
// d'horloge n'est nécessaire.
//
// Tout vit en mémoire. Une séance n'a de sens que tant que ses participants
// sont là : un redémarrage du serveur coupe aussi leurs flux vidéo.

const (
	// Durée maximale d'un long-poll. Sous le délai de réception de 30 s du
	// client Dio partagé, avec de la marge.
	watchPartyPollWindow = 20 * time.Second
	// Un participant qui n'a pas relancé de long-poll depuis ce délai est
	// parti : appli tuée, réseau coupé, télévision éteinte.
	watchPartyMemberStaleAfter = 50 * time.Second
	watchPartyReaperInterval   = 15 * time.Second
	// Au-delà, on cesse d'attendre un appareil qui charge : il rattrapera
	// seul, plutôt que de tenir tout le monde en pause indéfiniment.
	watchPartyWaitLimit = 20 * time.Second
	// Jusqu'où une attente peut ramener la séance en arrière : la position
	// de l'appareil qui charge, mais pas un rembobinage arbitraire.
	watchPartyMaxRewindOnWait = 15.0

	watchPartyCodeLength = 6
	watchPartyMaxMembers = 12
	watchPartyMaxParties = 256
)

// watchPartyAction dit qui a fait quoi en dernier, pour que les autres
// appareils puissent l'annoncer (« Alex a mis en pause »).
type watchPartyAction struct {
	Kind     string
	MemberID string
	Username string
	Version  int64
}

type watchPartyMember struct {
	ID       string
	UserID   int
	Username string
	Device   string
	JoinedAt time.Time
	LastSeen time.Time

	// Waiting : la séance attend cet appareil (il charge, il cherche, il
	// ouvre le média). Tant qu'un participant est attendu, la séance est
	// figée pour tout le monde, puis repart d'un seul geste.
	Waiting      bool
	WaitingSince time.Time
}

type watchParty struct {
	Code string

	MediaID  int
	Playing  bool
	Position float64 // secondes, à UpdatedAt
	Updated  time.Time

	Version    int64
	LastAction *watchPartyAction
	HostID     string
	Members    map[string]*watchPartyMember

	// Fermé puis remplacé à chaque changement : c'est ce qui réveille les
	// long-polls en attente.
	changed chan struct{}
}

// waiting dit si la séance attend au moins un participant.
func (p *watchParty) waiting() bool {
	for _, m := range p.Members {
		if m.Waiting {
			return true
		}
	}
	return false
}

// positionAt extrapole la position de référence à [now]. Elle n'avance que
// si la séance est en lecture et n'attend personne.
func (p *watchParty) positionAt(now time.Time) float64 {
	if !p.Playing || p.waiting() {
		return p.Position
	}
	elapsed := now.Sub(p.Updated).Seconds()
	if elapsed < 0 {
		elapsed = 0
	}
	return p.Position + elapsed
}

// rebase fige la position courante comme nouvelle référence. À appeler avant
// tout ce qui change la façon dont elle avance (lecture, attente).
func (p *watchParty) rebase(now time.Time) {
	p.Position = p.positionAt(now)
	p.Updated = now
}

// startWaiting met un participant en attente. [position] est l'endroit où
// cet appareil s'est arrêté : la séance s'y cale, pour que celui qui charge ne
// manque rien — les autres reculent d'autant, en pause.
func (p *watchParty) startWaiting(m *watchPartyMember, position *float64, now time.Time) {
	if m.Waiting {
		return
	}
	wasRunning := p.Playing && !p.waiting()
	p.rebase(now)
	if wasRunning && position != nil && *position >= 0 && *position < p.Position &&
		p.Position-*position <= watchPartyMaxRewindOnWait {
		p.Position = *position
	}
	m.Waiting = true
	m.WaitingSince = now
}

func (p *watchParty) stopWaiting(m *watchPartyMember, now time.Time) {
	if !m.Waiting {
		return
	}
	p.rebase(now)
	m.Waiting = false
}

// bump publie un changement : nouveau numéro, et réveil des attentes.
// À appeler verrou tenu.
func (p *watchParty) bump(action *watchPartyAction) {
	p.Version++
	if action != nil {
		action.Version = p.Version
		p.LastAction = action
	}
	close(p.changed)
	p.changed = make(chan struct{})
}

type watchPartyStore struct {
	mu      sync.Mutex
	parties map[string]*watchParty
}

var watchParties = &watchPartyStore{parties: make(map[string]*watchParty)}

var (
	errWatchPartyNotFound = errors.New("watch party not found")
	errWatchPartyFull     = errors.New("watch party full")
	errWatchPartyNotYours = errors.New("not a member of this watch party")
	errWatchPartyTooMany  = errors.New("too many watch parties")
)

func newWatchPartyMemberID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func generateWatchPartyCode() (string, error) {
	max := big.NewInt(int64(len(userCodeAlphabet)))
	out := make([]byte, watchPartyCodeLength)
	for i := range out {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		out[i] = userCodeAlphabet[n.Int64()]
	}
	return string(out), nil
}

func (s *watchPartyStore) create(member *watchPartyMember, mediaID int, position float64, playing bool, now time.Time) (*watchParty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.parties) >= watchPartyMaxParties {
		return nil, errWatchPartyTooMany
	}
	var code string
	for attempt := 0; ; attempt++ {
		c, err := generateWatchPartyCode()
		if err != nil {
			return nil, err
		}
		if _, taken := s.parties[c]; !taken {
			code = c
			break
		}
		if attempt > 16 {
			return nil, errWatchPartyTooMany
		}
	}
	member.JoinedAt, member.LastSeen = now, now
	party := &watchParty{
		Code:     code,
		MediaID:  mediaID,
		Playing:  playing,
		Position: position,
		Updated:  now,
		Version:  1,
		HostID:   member.ID,
		Members:  map[string]*watchPartyMember{member.ID: member},
		changed:  make(chan struct{}),
	}
	s.parties[code] = party
	return party, nil
}

func (s *watchPartyStore) join(code string, member *watchPartyMember, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	party, ok := s.parties[code]
	if !ok {
		return errWatchPartyNotFound
	}
	if len(party.Members) >= watchPartyMaxMembers {
		return errWatchPartyFull
	}
	member.JoinedAt, member.LastSeen = now, now
	party.Members[member.ID] = member
	// Les autres attendent que le nouveau venu ait son image, pour partir
	// ensemble.
	party.startWaiting(member, nil, now)
	party.bump(&watchPartyAction{Kind: "join", MemberID: member.ID, Username: member.Username})
	return nil
}

// member retrouve un participant et vérifie qu'il appartient bien au compte
// qui appelle : l'identifiant de participant ne suffit pas à agir en son nom.
// À appeler verrou tenu.
func (s *watchPartyStore) member(code, memberID string, userID int) (*watchParty, *watchPartyMember, error) {
	party, ok := s.parties[code]
	if !ok {
		return nil, nil, errWatchPartyNotFound
	}
	m, ok := party.Members[memberID]
	if !ok {
		return nil, nil, errWatchPartyNotFound
	}
	if m.UserID != userID {
		return nil, nil, errWatchPartyNotYours
	}
	return party, m, nil
}

type watchPartyUpdate struct {
	MemberID string   `json:"member_id"`
	Action   string   `json:"action"`
	Playing  *bool    `json:"playing"`
	Position *float64 `json:"position_seconds"`
	MediaID  int      `json:"media_id"`
	// Loading accompagne l'action "loading" : l'appareil charge (true) ou est
	// prêt (false).
	Loading *bool `json:"loading"`
}

func (s *watchPartyStore) update(code string, userID int, req watchPartyUpdate, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	party, m, err := s.member(code, req.MemberID, userID)
	if err != nil {
		return err
	}
	m.LastSeen = now

	// Un appareil qui charge ou qui est de nouveau prêt n'est pas un geste :
	// il ne change ni la lecture ni la position voulues, seulement l'attente.
	if req.Action == "loading" {
		if req.Loading == nil {
			return nil
		}
		if *req.Loading {
			if m.Waiting {
				return nil
			}
			party.startWaiting(m, req.Position, now)
		} else {
			if !m.Waiting {
				return nil
			}
			party.stopWaiting(m, now)
		}
		party.bump(nil)
		return nil
	}

	// La position de départ est celle extrapolée : une pause sans position
	// fige la séance là où elle en est, pas là où elle en était au dernier
	// changement.
	party.Position = party.positionAt(now)
	party.Updated = now
	if req.MediaID > 0 && req.MediaID != party.MediaID {
		party.MediaID = req.MediaID
		party.Position = 0
		// Tout le monde ouvre le nouveau média : on attend chacun.
		for _, other := range party.Members {
			other.Waiting = true
			other.WaitingSince = now
		}
	}
	if req.Position != nil && *req.Position >= 0 {
		party.Position = *req.Position
	}
	if req.Playing != nil {
		party.Playing = *req.Playing
	}
	party.bump(&watchPartyAction{Kind: req.Action, MemberID: m.ID, Username: m.Username})
	return nil
}

func (s *watchPartyStore) leave(code, memberID string, userID int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	party, m, err := s.member(code, memberID, userID)
	if err != nil {
		return err
	}
	s.removeLocked(party, m, "leave", time.Now())
	return nil
}

// removeLocked retire un participant ; une séance vide disparaît, et l'hôte
// qui part passe la main au plus ancien des restants.
func (s *watchPartyStore) removeLocked(party *watchParty, m *watchPartyMember, kind string, now time.Time) {
	// Un participant attendu qui s'en va libère les autres : la position
	// doit repartir d'ici, pas de son arrivée.
	party.rebase(now)
	delete(party.Members, m.ID)
	if len(party.Members) == 0 {
		delete(s.parties, party.Code)
		close(party.changed)
		return
	}
	if party.HostID == m.ID {
		var next *watchPartyMember
		for _, other := range party.Members {
			if next == nil || other.JoinedAt.Before(next.JoinedAt) {
				next = other
			}
		}
		party.HostID = next.ID
	}
	party.bump(&watchPartyAction{Kind: kind, MemberID: m.ID, Username: m.Username})
}

// expireWaits cesse d'attendre les appareils qui chargent depuis trop
// longtemps.
func (s *watchPartyStore) expireWaits(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, party := range s.parties {
		changed := false
		for _, m := range party.Members {
			if m.Waiting && now.Sub(m.WaitingSince) > watchPartyWaitLimit {
				party.stopWaiting(m, now)
				changed = true
			}
		}
		if changed {
			party.bump(nil)
		}
	}
}

func (s *watchPartyStore) reap(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, party := range s.parties {
		for _, m := range party.Members {
			if now.Sub(m.LastSeen) > watchPartyMemberStaleAfter {
				s.removeLocked(party, m, "leave", now)
			}
		}
	}
}

// RunWatchParties purge les participants partis sans prévenir et lève les
// attentes trop longues.
func RunWatchParties(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lastReap := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			watchParties.expireWaits(now)
			if now.Sub(lastReap) >= watchPartyReaperInterval {
				lastReap = now
				watchParties.reap(now)
			}
		}
	}
}

// --- Réponses -----------------------------------------------------------

type watchPartyMemberView struct {
	Username string `json:"username"`
	Device   string `json:"device,omitempty"`
	IsHost   bool   `json:"is_host"`
	IsYou    bool   `json:"is_you"`
}

type watchPartyActionView struct {
	Kind     string `json:"kind"`
	Username string `json:"username"`
	ByYou    bool   `json:"by_you"`
	Version  int64  `json:"version"`
}

type watchPartyView struct {
	Code     string                 `json:"code"`
	MemberID string                 `json:"member_id"`
	Version  int64                  `json:"version"`
	MediaID  int                    `json:"media_id"`
	Media    *models.HomeMediaItem  `json:"media,omitempty"`
	Playing  bool                   `json:"playing"`
	Position float64                `json:"position_seconds"`
	Members  []watchPartyMemberView `json:"members"`
	Action   *watchPartyActionView  `json:"last_action,omitempty"`
	// Les participants que la séance attend. Tant que la liste n'est pas
	// vide, la position est figée, même si Playing est vrai.
	WaitingFor    []string `json:"waiting_for"`
	WaitingForYou bool     `json:"waiting_for_you"`
}

// view photographie la séance du point de vue d'un participant. À appeler
// verrou tenu ; le média est chargé après, hors verrou.
func (p *watchParty) view(memberID string, now time.Time) watchPartyView {
	v := watchPartyView{
		Code:     p.Code,
		MemberID: memberID,
		Version:  p.Version,
		MediaID:  p.MediaID,
		Playing:  p.Playing,
		Position: p.positionAt(now),
		Members:  make([]watchPartyMemberView, 0, len(p.Members)),

		WaitingFor: []string{},
	}
	members := make([]*watchPartyMember, 0, len(p.Members))
	for _, m := range p.Members {
		members = append(members, m)
	}
	sort.Slice(members, func(i, j int) bool { return members[i].JoinedAt.Before(members[j].JoinedAt) })
	for _, m := range members {
		if m.Waiting {
			if m.ID == memberID {
				v.WaitingForYou = true
			} else {
				v.WaitingFor = append(v.WaitingFor, m.Username)
			}
		}
		v.Members = append(v.Members, watchPartyMemberView{
			Username: m.Username,
			Device:   m.Device,
			IsHost:   m.ID == p.HostID,
			IsYou:    m.ID == memberID,
		})
	}
	if a := p.LastAction; a != nil {
		v.Action = &watchPartyActionView{
			Kind:     a.Kind,
			Username: a.Username,
			ByYou:    a.MemberID == memberID,
			Version:  a.Version,
		}
	}
	return v
}

// loadWatchPartyMedia charge le média lisible tel que ce compte le voit (sa
// propre progression, et pour un épisode la saison et la série).
func loadWatchPartyMedia(userID, mediaID int) (*models.HomeMediaItem, error) {
	var mediaType string
	var filePath string
	err := database.DB.QueryRow(
		`SELECT type, COALESCE(file_path, '') FROM medias WHERE id = ?`, mediaID,
	).Scan(&mediaType, &filePath)
	if err != nil {
		return nil, err
	}
	if filePath == "" {
		return nil, sql.ErrNoRows
	}
	var item models.HomeMediaItem
	switch models.MediaType(mediaType) {
	case models.TypeEpisode:
		item, err = scanEpisodeItem(database.DB.QueryRow(`
			SELECT `+episodeItemColumns+`
			FROM medias m
			LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
			LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
			LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
			WHERE m.id = ?`, userID, mediaID))
	case models.TypeMovie:
		item, err = scanLibraryItem(database.DB.QueryRow(`
			SELECT `+libraryItemColumns+`
			FROM medias m
			LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
			WHERE m.id = ?`, userID, mediaID))
	default:
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return &item, nil
}

func writeWatchPartyView(w http.ResponseWriter, userID int, v watchPartyView) {
	if item, err := loadWatchPartyMedia(userID, v.MediaID); err == nil {
		v.Media = item
	} else if err != sql.ErrNoRows {
		log.Printf("WatchParty: media %d: %v", v.MediaID, err)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(v)
}

func writeWatchPartyError(w http.ResponseWriter, err error) {
	switch err {
	case errWatchPartyNotFound:
		writeJSONError(w, http.StatusNotFound, "Séance introuvable ou terminée")
	case errWatchPartyNotYours:
		writeJSONError(w, http.StatusForbidden, "Vous ne faites pas partie de cette séance")
	case errWatchPartyFull:
		writeJSONError(w, http.StatusConflict, "La séance est complète")
	case errWatchPartyTooMany:
		writeJSONError(w, http.StatusServiceUnavailable, "Trop de séances en cours")
	default:
		writeJSONError(w, http.StatusInternalServerError, "Séance indisponible")
	}
}

func newWatchPartyMember(r *http.Request, userID int) (*watchPartyMember, error) {
	id, err := newWatchPartyMemberID()
	if err != nil {
		return nil, err
	}
	var username string
	_ = database.DB.QueryRow(`SELECT username FROM users WHERE id = ?`, userID).Scan(&username)
	client, _ := sessionClientSnapshot(bearerToken(r))
	return &watchPartyMember{ID: id, UserID: userID, Username: username, Device: client.device}, nil
}

// --- Routes ---------------------------------------------------------------

// CreateWatchParty ouvre une séance sur le média en cours (POST /api/watch-parties).
func CreateWatchParty(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var body struct {
		MediaID  int     `json:"media_id"`
		Position float64 `json:"position_seconds"`
		Playing  bool    `json:"playing"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body) != nil || body.MediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media id")
		return
	}
	if _, err := loadWatchPartyMedia(userID, body.MediaID); err != nil {
		writeJSONError(w, http.StatusNotFound, "Playable media not found")
		return
	}
	if body.Position < 0 {
		body.Position = 0
	}
	member, err := newWatchPartyMember(r, userID)
	if err != nil {
		writeWatchPartyError(w, err)
		return
	}
	now := time.Now()
	party, err := watchParties.create(member, body.MediaID, body.Position, body.Playing, now)
	if err != nil {
		writeWatchPartyError(w, err)
		return
	}
	watchParties.mu.Lock()
	v := party.view(member.ID, now)
	watchParties.mu.Unlock()
	writeWatchPartyView(w, userID, v)
}

// JoinWatchParty rejoint une séance par son code (POST /api/watch-parties/:code/join).
func JoinWatchParty(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	code := normalizeUserCode(ps.ByName("code"))
	member, err := newWatchPartyMember(r, userID)
	if err != nil {
		writeWatchPartyError(w, err)
		return
	}
	now := time.Now()
	if err := watchParties.join(code, member, now); err != nil {
		writeWatchPartyError(w, err)
		return
	}
	watchParties.mu.Lock()
	party, ok := watchParties.parties[code]
	var v watchPartyView
	if ok {
		v = party.view(member.ID, now)
	}
	watchParties.mu.Unlock()
	if !ok {
		writeWatchPartyError(w, errWatchPartyNotFound)
		return
	}
	writeWatchPartyView(w, userID, v)
}

// PollWatchParty attend le prochain changement de la séance
// (GET /api/watch-parties/:code?member=…&since=N). Répond tout de suite si la
// séance a déjà dépassé N, sinon au premier changement ou au bout de
// [watchPartyPollWindow] — ce qui sert aussi de signe de vie du participant.
func PollWatchParty(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	code := normalizeUserCode(ps.ByName("code"))
	memberID := r.URL.Query().Get("member")
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)

	watchParties.mu.Lock()
	party, m, err := watchParties.member(code, memberID, userID)
	if err != nil {
		watchParties.mu.Unlock()
		writeWatchPartyError(w, err)
		return
	}
	m.LastSeen = time.Now()
	wait := party.changed
	ready := party.Version > since
	watchParties.mu.Unlock()

	if !ready {
		timer := time.NewTimer(watchPartyPollWindow)
		select {
		case <-wait:
		case <-timer.C:
		case <-r.Context().Done():
			timer.Stop()
			return
		}
		timer.Stop()
	}

	now := time.Now()
	watchParties.mu.Lock()
	party, m, err = watchParties.member(code, memberID, userID)
	if err != nil {
		watchParties.mu.Unlock()
		writeWatchPartyError(w, err)
		return
	}
	m.LastSeen = now
	v := party.view(memberID, now)
	watchParties.mu.Unlock()
	writeWatchPartyView(w, userID, v)
}

// UpdateWatchParty applique le geste d'un participant à toute la séance
// (POST /api/watch-parties/:code/state).
func UpdateWatchParty(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	code := normalizeUserCode(ps.ByName("code"))
	var req watchPartyUpdate
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req) != nil || req.MemberID == "" {
		writeJSONError(w, http.StatusBadRequest, "Invalid watch party update")
		return
	}
	switch req.Action {
	case "play", "pause", "seek", "media", "loading":
	default:
		writeJSONError(w, http.StatusBadRequest, "Unknown action")
		return
	}
	if req.MediaID > 0 {
		if _, err := loadWatchPartyMedia(userID, req.MediaID); err != nil {
			writeJSONError(w, http.StatusNotFound, "Playable media not found")
			return
		}
	}
	now := time.Now()
	if err := watchParties.update(code, userID, req, now); err != nil {
		writeWatchPartyError(w, err)
		return
	}
	watchParties.mu.Lock()
	party, ok := watchParties.parties[code]
	var v watchPartyView
	if ok {
		v = party.view(req.MemberID, now)
	}
	watchParties.mu.Unlock()
	if !ok {
		writeWatchPartyError(w, errWatchPartyNotFound)
		return
	}
	writeWatchPartyView(w, userID, v)
}

// LeaveWatchParty quitte une séance (POST /api/watch-parties/:code/leave).
func LeaveWatchParty(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	code := normalizeUserCode(ps.ByName("code"))
	var body struct {
		MemberID string `json:"member_id"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body) != nil || body.MemberID == "" {
		writeJSONError(w, http.StatusBadRequest, "Invalid member id")
		return
	}
	if err := watchParties.leave(code, body.MemberID, userID); err != nil && err != errWatchPartyNotFound {
		writeWatchPartyError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
