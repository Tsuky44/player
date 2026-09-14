package handlers

import (
	"bytes"
	"context"
	"crypto/subtle"
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
	"time"

	"project-player/server/config"
	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// Serveurs liés — ADR-0017.
//
// Deux serveurs qui ont chacun un compte à la même personne peuvent se lier.
// La liaison vit sur les serveurs, plus sur un appareil : un lien fait depuis
// le téléphone vaut pour la télévision, et la progression part d'un serveur à
// l'autre même quand aucune app n'est ouverte.
//
// Trois étages :
//   - la paire de serveurs (peer_servers), qui n'a cours qu'une fois acceptée
//     par un administrateur de chaque côté — une seule fois par paire ;
//   - les liens de comptes (account_links), créés par la personne elle-même :
//     elle prouve détenir les deux comptes en demandant un code à l'un et en le
//     remettant à l'autre, sans qu'aucun jeton ne change de serveur ;
//   - la transmission, faite par une tâche de fond qui suit progress_changes.

const (
	linkCodeTTL       = 10 * time.Minute
	federationTick    = 5 * time.Second
	federationBatch   = 500
	federationVersion = 1
	peerHeader        = "X-Onyx-Server"
)

var federationClient = &http.Client{
	Timeout: 15 * time.Second,
	// Un serveur lié qui redirige ailleurs n'est plus celui qu'on a accepté.
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// PeerServer est ce que voit un administrateur.
type PeerServer struct {
	ID             int        `json:"id"`
	ServerID       string     `json:"server_id"`
	Name           string     `json:"name"`
	URL            string     `json:"url"`
	LocalApproved  bool       `json:"local_approved"`
	RemoteApproved bool       `json:"remote_approved"`
	Active         bool       `json:"active"`
	Accounts       int        `json:"accounts"`
	LastError      string     `json:"last_error,omitempty"`
	LastContactAt  *time.Time `json:"last_contact_at,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
}

// AccountLink est ce que voit la personne : ses comptes sur les autres serveurs.
type AccountLink struct {
	ID             int    `json:"id"`
	ServerID       string `json:"server_id"`
	ServerName     string `json:"server_name"`
	URL            string `json:"url"`
	RemoteUserID   int    `json:"remote_user_id"`
	RemoteUsername string `json:"remote_username"`
	// Status vaut "active", ou "pending" tant qu'un des deux administrateurs
	// n'a pas accepté la paire de serveurs.
	Status string `json:"status"`
}

type federationInfo struct {
	ServerID   string `json:"server_id"`
	Name       string `json:"name"`
	Federation int    `json:"federation"`
}

type peerRow struct {
	id             int
	serverID       string
	name           string
	url            string
	secret         string
	localApproved  bool
	remoteApproved bool
}

type claimBody struct {
	Code     string `json:"code"`
	ServerID string `json:"server_id"`
	Name     string `json:"name"`
	URL      string `json:"url"`
	Secret   string `json:"secret"`
	Approved bool   `json:"approved"`
	UserID   int    `json:"user_id"`
	Username string `json:"username"`
}

type claimResponse struct {
	ServerID string `json:"server_id"`
	Name     string `json:"name"`
	UserID   int    `json:"user_id"`
	Username string `json:"username"`
	Approved bool   `json:"approved"`
}

type peerProgressBody struct {
	FromUserID int                `json:"from_user_id"`
	ToUserID   int                `json:"to_user_id"`
	Entries    []PortableProgress `json:"entries"`
}

type peerUnlinkBody struct {
	FromUserID int `json:"from_user_id"`
	ToUserID   int `json:"to_user_id"`
}

// ==================== OUTILS ====================

// normalizeServerURL garde un schéma http(s) et un hôte, sans barre finale.
func normalizeServerURL(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw != "" && !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return "", false
	}
	return strings.TrimRight(parsed.Scheme+"://"+parsed.Host+parsed.Path, "/"), true
}

const peerColumns = `id, server_id, name, url, secret, local_approved, remote_approved`

func scanPeer(row rowScanner) (peerRow, error) {
	var p peerRow
	err := row.Scan(&p.id, &p.serverID, &p.name, &p.url, &p.secret, &p.localApproved, &p.remoteApproved)
	return p, err
}

// peerCall parle à un serveur lié en présentant le secret de la paire.
func peerCall(ctx context.Context, peer peerRow, path string, body any, out any) (int, error) {
	return federationPost(ctx, peer.url+path, body, out, func(req *http.Request) {
		req.Header.Set(peerHeader, config.ServerID())
		req.Header.Set("Authorization", "Bearer "+peer.secret)
	})
}

func federationPost(ctx context.Context, target string, body any, out any, decorate func(*http.Request)) (int, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if decorate != nil {
		decorate(req)
	}
	resp, err := federationClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return resp.StatusCode, errors.New(remoteErrorMessage(data, resp.StatusCode))
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

func remoteErrorMessage(data []byte, status int) string {
	var body struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(data, &body) == nil && body.Error != "" {
		return body.Error
	}
	return fmt.Sprintf("HTTP %d", status)
}

func fetchFederationInfo(ctx context.Context, base string) (federationInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/api/federation/info", nil)
	if err != nil {
		return federationInfo{}, err
	}
	resp, err := federationClient.Do(req)
	if err != nil {
		return federationInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return federationInfo{}, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var info federationInfo
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&info); err != nil {
		return federationInfo{}, err
	}
	if info.ServerID == "" || info.Federation < 1 {
		return federationInfo{}, errors.New("serveur sans prise en charge des liens")
	}
	return info, nil
}

var federationWake = make(chan struct{}, 1)

// wakeFederation avance la prochaine passe de transmission.
func wakeFederation() {
	select {
	case federationWake <- struct{}{}:
	default:
	}
}

// ==================== ROUTES PUBLIQUES ====================

// GetFederationInfo dit qui est ce serveur (GET /api/federation/info).
func GetFederationInfo(w http.ResponseWriter, _ *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(federationInfo{
		ServerID: config.ServerID(), Name: config.ServerName(), Federation: federationVersion,
	})
}

// ClaimAccountLink reçoit la demande de lien d'un autre serveur
// (POST /api/federation/claim).
//
// Ouverte parce que la paire n'existe peut-être pas encore, mais rien n'y entre
// sans un code de liaison émis ici pour un compte d'ici : seul quelqu'un qui
// détient ce compte a pu le fabriquer. Le code est à usage unique.
func ClaimAccountLink(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")
	var body claimBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	peerURL, okURL := normalizeServerURL(body.URL)
	body.Name = strings.TrimSpace(body.Name)
	body.Username = strings.TrimSpace(body.Username)
	if body.Code == "" || body.ServerID == "" || len(body.ServerID) > 64 || len(body.Secret) < 32 ||
		!okURL || body.UserID <= 0 || len(body.Name) > 128 || len(body.Username) > 64 {
		writeJSONError(w, http.StatusBadRequest, "Demande de lien invalide")
		return
	}
	if body.ServerID == config.ServerID() {
		writeJSONError(w, http.StatusBadRequest, "Impossible de lier un serveur à lui-même")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer tx.Rollback()

	var userID int
	var username string
	err = tx.QueryRow(`SELECT c.user_id, u.username FROM link_codes c JOIN users u ON u.id = c.user_id
		WHERE c.code = ? AND c.expires_at > ?`, body.Code, time.Now().UTC().Format(progressTimeLayout)).
		Scan(&userID, &username)
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusBadRequest, "Code de liaison invalide ou expiré")
		return
	}
	if err != nil {
		log.Printf("ClaimAccountLink code: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	peer, err := scanPeer(tx.QueryRow(`SELECT `+peerColumns+` FROM peer_servers WHERE server_id = ?`, body.ServerID))
	switch {
	case err == sql.ErrNoRows:
		res, insErr := tx.Exec(`INSERT INTO peer_servers (server_id, name, url, secret, remote_approved)
			VALUES (?, ?, ?, ?, ?)`, body.ServerID, body.Name, peerURL, body.Secret, body.Approved)
		if insErr != nil {
			log.Printf("ClaimAccountLink insert peer: %v", insErr)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		id, _ := res.LastInsertId()
		peer = peerRow{id: int(id), serverID: body.ServerID}
	case err != nil:
		log.Printf("ClaimAccountLink peer: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	default:
		if subtle.ConstantTimeCompare([]byte(peer.secret), []byte(body.Secret)) != 1 {
			writeJSONError(w, http.StatusConflict,
				"Ce serveur est déjà lié avec une autre clé. Un administrateur doit retirer l’ancien lien.")
			return
		}
		if _, err := tx.Exec(`UPDATE peer_servers SET name = ?, url = ?, remote_approved = ? WHERE id = ?`,
			body.Name, peerURL, body.Approved, peer.id); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
	}

	if msg := insertAccountLink(tx, userID, peer.id, body.UserID, body.Username); msg != "" {
		writeJSONError(w, http.StatusConflict, msg)
		return
	}
	if _, err := tx.Exec(`DELETE FROM link_codes WHERE code = ?`, body.Code); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	var localApproved bool
	_ = tx.QueryRow(`SELECT local_approved FROM peer_servers WHERE id = ?`, peer.id).Scan(&localApproved)
	if err := tx.Commit(); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	wakeFederation()
	json.NewEncoder(w).Encode(claimResponse{
		ServerID: config.ServerID(), Name: config.ServerName(),
		UserID: userID, Username: username, Approved: localApproved,
	})
}

// insertAccountLink rend un message quand l'un des deux comptes est déjà lié à
// quelqu'un d'autre sur ce serveur distant. Refaire le même lien ne change rien.
func insertAccountLink(tx *sql.Tx, userID, peerID, remoteUserID int, remoteUsername string) string {
	var existingRemote, existingLocal int
	err := tx.QueryRow(`SELECT remote_user_id FROM account_links WHERE peer_id = ? AND user_id = ?`,
		peerID, userID).Scan(&existingRemote)
	if err == nil && existingRemote != remoteUserID {
		return "Ce compte est déjà lié à un autre compte de ce serveur"
	}
	err = tx.QueryRow(`SELECT user_id FROM account_links WHERE peer_id = ? AND remote_user_id = ?`,
		peerID, remoteUserID).Scan(&existingLocal)
	if err == nil && existingLocal != userID {
		return "L’autre compte est déjà lié à un autre compte de ce serveur"
	}
	if _, err := tx.Exec(`INSERT INTO account_links (user_id, peer_id, remote_user_id, remote_username)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(peer_id, user_id) DO UPDATE SET remote_username = excluded.remote_username`,
		userID, peerID, remoteUserID, remoteUsername); err != nil {
		log.Printf("insertAccountLink: %v", err)
		return "Impossible d’enregistrer le lien"
	}
	return ""
}

// ==================== ROUTES ENTRE SERVEURS ====================

type peerHandle func(w http.ResponseWriter, r *http.Request, peer peerRow)

// RequirePeer authentifie un serveur lié par son identité et le secret de la
// paire. Un serveur inconnu reçoit 401 : c'est ce qui dit à l'autre côté que
// le lien a été retiré ici.
func RequirePeer(next peerHandle) httprouter.Handle {
	return func(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
		w.Header().Set("Content-Type", "application/json")
		serverID := r.Header.Get(peerHeader)
		secret := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		peer, err := scanPeer(database.DB.QueryRow(`SELECT `+peerColumns+` FROM peer_servers WHERE server_id = ?`, serverID))
		if err != nil || serverID == "" || subtle.ConstantTimeCompare([]byte(peer.secret), []byte(secret)) != 1 {
			writeJSONError(w, http.StatusUnauthorized, "peer_unknown")
			return
		}
		_, _ = database.DB.Exec(`UPDATE peer_servers SET last_contact_at = CURRENT_TIMESTAMP WHERE id = ?`, peer.id)
		next(w, r, peer)
	}
}

// PeerApproval : l'administrateur de l'autre serveur a accepté la paire
// (POST /api/federation/approval).
func PeerApproval(w http.ResponseWriter, r *http.Request, peer peerRow) {
	if _, err := database.DB.Exec(`UPDATE peer_servers SET remote_approved = 1 WHERE id = ?`, peer.id); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	wakeFederation()
	w.Write([]byte(`{"status":"ok"}`))
}

// PeerProgress reçoit la progression d'un compte lié (POST /api/federation/progress).
func PeerProgress(w http.ResponseWriter, r *http.Request, peer peerRow) {
	var body peerProgressBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&body); err != nil ||
		len(body.Entries) > federationBatch {
		writeJSONError(w, http.StatusBadRequest, "Invalid progress batch")
		return
	}
	if !peer.localApproved {
		writeJSONError(w, http.StatusForbidden, "peer_not_approved")
		return
	}
	var linkID int
	err := database.DB.QueryRow(`SELECT id FROM account_links WHERE peer_id = ? AND user_id = ? AND remote_user_id = ?`,
		peer.id, body.ToUserID, body.FromUserID).Scan(&linkID)
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "link_unknown")
		return
	}
	if msg := validatePortableProgress(body.Entries); msg != "" {
		writeJSONError(w, http.StatusBadRequest, msg)
		return
	}
	// Un envoi prouve que l'autre administrateur a accepté : l'autre côté ne
	// transmet rien tant que ce n'est pas le cas.
	if !peer.remoteApproved {
		_, _ = database.DB.Exec(`UPDATE peer_servers SET remote_approved = 1 WHERE id = ?`, peer.id)
	}
	if err := importPortableProgress(body.ToUserID, body.Entries); err != nil {
		log.Printf("PeerProgress import: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Unable to save progress")
		return
	}
	w.Write([]byte(`{"status":"ok"}`))
}

// PeerUnlink : la personne a dissocié ses comptes depuis l'autre serveur
// (POST /api/federation/unlink).
func PeerUnlink(w http.ResponseWriter, r *http.Request, peer peerRow) {
	var body peerUnlinkBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if _, err := database.DB.Exec(`DELETE FROM account_links WHERE peer_id = ? AND user_id = ? AND remote_user_id = ?`,
		peer.id, body.ToUserID, body.FromUserID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status":"ok"}`))
}

// PeerForget : l'autre serveur a retiré ou refusé la paire
// (POST /api/federation/forget). Les liens de comptes partent avec elle.
func PeerForget(w http.ResponseWriter, _ *http.Request, peer peerRow) {
	if _, err := database.DB.Exec(`DELETE FROM peer_servers WHERE id = ?`, peer.id); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status":"ok"}`))
}

// ==================== ROUTES DU COMPTE ====================

// CreateLinkCode émet la preuve qu'on détient ce compte (POST /api/links/code).
func CreateLinkCode(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")
	code, err := GenerateRandomToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	now := time.Now().UTC()
	_, _ = database.DB.Exec(`DELETE FROM link_codes WHERE expires_at <= ?`, now.Format(progressTimeLayout))
	if _, err := database.DB.Exec(`INSERT INTO link_codes (code, user_id, expires_at) VALUES (?, ?, ?)`,
		code, userID, now.Add(linkCodeTTL).Format(progressTimeLayout)); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	json.NewEncoder(w).Encode(map[string]any{
		"code": code, "expires_in": int(linkCodeTTL.Seconds()), "server_id": config.ServerID(),
	})
}

type createLinkBody struct {
	// URL est l'adresse de l'autre serveur, telle que l'appareil la joint.
	URL string `json:"url"`
	// SelfURL est l'adresse de ce serveur-ci, telle que l'appareil la joint :
	// l'autre serveur s'en servira pour transmettre dans l'autre sens.
	SelfURL string `json:"self_url"`
	Code    string `json:"code"`
}

// CreateAccountLink lie le compte courant à celui qui a émis le code sur un
// autre serveur (POST /api/links). C'est ce serveur-ci qui appelle l'autre :
// l'appareil ne fait que transmettre le code, jamais un jeton.
func CreateAccountLink(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")
	var body createLinkBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	peerURL, okPeer := normalizeServerURL(body.URL)
	selfURL, okSelf := normalizeServerURL(body.SelfURL)
	if !okPeer || !okSelf || strings.TrimSpace(body.Code) == "" {
		writeJSONError(w, http.StatusBadRequest, "Adresse ou code de liaison invalide")
		return
	}
	var username string
	if err := database.DB.QueryRow(`SELECT username FROM users WHERE id = ?`, userID).Scan(&username); err != nil {
		writeJSONError(w, http.StatusUnauthorized, "Invalid or expired session")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	info, err := fetchFederationInfo(ctx, peerURL)
	if err != nil {
		writeJSONError(w, http.StatusBadGateway,
			"Ce serveur ne parvient pas à joindre "+peerURL+" ("+err.Error()+"). Les deux serveurs doivent pouvoir se joindre.")
		return
	}
	if info.ServerID == config.ServerID() {
		writeJSONError(w, http.StatusBadRequest, "Ces deux comptes sont sur le même serveur")
		return
	}

	existing, err := scanPeer(database.DB.QueryRow(`SELECT `+peerColumns+` FROM peer_servers WHERE server_id = ?`, info.ServerID))
	if err != nil && err != sql.ErrNoRows {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	known := err == nil
	secret := existing.secret
	if !known {
		if secret, err = GenerateRandomToken(); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
	}

	var claimed claimResponse
	status, err := federationPost(ctx, peerURL+"/api/federation/claim", claimBody{
		Code: body.Code, ServerID: config.ServerID(), Name: config.ServerName(), URL: selfURL,
		Secret: secret, Approved: known && existing.localApproved, UserID: userID, Username: username,
	}, &claimed, nil)
	if err != nil {
		code := http.StatusBadGateway
		if status == http.StatusBadRequest || status == http.StatusConflict {
			code = http.StatusConflict
		}
		writeJSONError(w, code, err.Error())
		return
	}
	if claimed.ServerID != info.ServerID || claimed.UserID <= 0 {
		writeJSONError(w, http.StatusBadGateway, "Réponse incohérente de l’autre serveur")
		return
	}

	tx, err := database.DB.Begin()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer tx.Rollback()
	peerID := existing.id
	if known {
		_, err = tx.Exec(`UPDATE peer_servers SET name = ?, url = ?, remote_approved = ? WHERE id = ?`,
			claimed.Name, peerURL, claimed.Approved, peerID)
	} else {
		var res sql.Result
		res, err = tx.Exec(`INSERT INTO peer_servers (server_id, name, url, secret, remote_approved)
			VALUES (?, ?, ?, ?, ?)`, info.ServerID, claimed.Name, peerURL, secret, claimed.Approved)
		if err == nil {
			id, _ := res.LastInsertId()
			peerID = int(id)
		}
	}
	if err != nil {
		log.Printf("CreateAccountLink peer: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if msg := insertAccountLink(tx, userID, peerID, claimed.UserID, claimed.Username); msg != "" {
		writeJSONError(w, http.StatusConflict, msg)
		return
	}
	if err := tx.Commit(); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	wakeFederation()

	links, err := listAccountLinks(userID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	for _, link := range links {
		if link.ServerID == info.ServerID {
			json.NewEncoder(w).Encode(link)
			return
		}
	}
	writeJSONError(w, http.StatusInternalServerError, "Internal server error")
}

func listAccountLinks(userID int) ([]AccountLink, error) {
	rows, err := database.DB.Query(`SELECT l.id, p.server_id, p.name, p.url, l.remote_user_id, l.remote_username,
		p.local_approved, p.remote_approved
		FROM account_links l JOIN peer_servers p ON p.id = l.peer_id
		WHERE l.user_id = ? ORDER BY l.created_at, l.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	links := []AccountLink{}
	for rows.Next() {
		var link AccountLink
		var local, remote bool
		if err := rows.Scan(&link.ID, &link.ServerID, &link.ServerName, &link.URL,
			&link.RemoteUserID, &link.RemoteUsername, &local, &remote); err != nil {
			return nil, err
		}
		link.Status = "pending"
		if local && remote {
			link.Status = "active"
		}
		links = append(links, link)
	}
	return links, rows.Err()
}

// ListAccountLinks rend les comptes liés de la personne (GET /api/links). C'est
// ce qui permet à un autre appareil de retrouver ses serveurs.
func ListAccountLinks(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")
	links, err := listAccountLinks(userID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	json.NewEncoder(w).Encode(links)
}

// DeleteAccountLink dissocie deux comptes (DELETE /api/links/:id). L'autre
// serveur est prévenu s'il répond ; sinon il l'apprendra à son prochain envoi.
// L'historique déjà partagé reste de chaque côté.
func DeleteAccountLink(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid link id")
		return
	}
	var remoteUserID int
	peer, err := scanPeer(database.DB.QueryRow(`SELECT p.id, p.server_id, p.name, p.url, p.secret,
		p.local_approved, p.remote_approved FROM account_links l JOIN peer_servers p ON p.id = l.peer_id
		WHERE l.id = ? AND l.user_id = ?`, id, userID))
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusNotFound, "Lien introuvable")
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	_ = database.DB.QueryRow(`SELECT remote_user_id FROM account_links WHERE id = ?`, id).Scan(&remoteUserID)
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	_, _ = peerCall(ctx, peer, "/api/federation/unlink", peerUnlinkBody{FromUserID: userID, ToUserID: remoteUserID}, nil)
	if _, err := database.DB.Exec(`DELETE FROM account_links WHERE id = ? AND user_id = ?`, id, userID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status":"ok"}`))
}

// ==================== ROUTES D'ADMINISTRATION ====================

func loadPeerServers(where string, args ...any) ([]PeerServer, error) {
	rows, err := database.DB.Query(`SELECT p.id, p.server_id, p.name, p.url, p.local_approved, p.remote_approved,
		p.last_error, p.last_contact_at, p.created_at,
		(SELECT COUNT(*) FROM account_links l WHERE l.peer_id = p.id)
		FROM peer_servers p `+where+` ORDER BY p.created_at, p.id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	peers := []PeerServer{}
	for rows.Next() {
		var p PeerServer
		var contact, created sql.NullString
		if err := rows.Scan(&p.ID, &p.ServerID, &p.Name, &p.URL, &p.LocalApproved, &p.RemoteApproved,
			&p.LastError, &contact, &created, &p.Accounts); err != nil {
			return nil, err
		}
		if t := scanSQLiteTime(contact); !t.IsZero() {
			p.LastContactAt = &t
		}
		p.CreatedAt = scanSQLiteTime(created)
		p.Active = p.LocalApproved && p.RemoteApproved
		peers = append(peers, p)
	}
	return peers, rows.Err()
}

// ListPeerServers (GET /api/peers).
func ListPeerServers(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	peers, err := loadPeerServers("")
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	json.NewEncoder(w).Encode(peers)
}

func writePeer(w http.ResponseWriter, id int) {
	peers, err := loadPeerServers("WHERE p.id = ?", id)
	if err != nil || len(peers) == 0 {
		writeJSONError(w, http.StatusNotFound, "Serveur introuvable")
		return
	}
	json.NewEncoder(w).Encode(peers[0])
}

// ApprovePeerServer accepte la paire (POST /api/peers/:id/approve). Une fois
// pour toutes : les liens que d'autres comptes feront ensuite entre ces deux
// serveurs n'auront pas à être acceptés de nouveau.
func ApprovePeerServer(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid id")
		return
	}
	res, err := database.DB.Exec(`UPDATE peer_servers SET local_approved = 1, approval_sent = 0 WHERE id = ?`, id)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONError(w, http.StatusNotFound, "Serveur introuvable")
		return
	}
	wakeFederation()
	writePeer(w, id)
}

type updatePeerBody struct {
	URL string `json:"url"`
}

// UpdatePeerServer corrige l'adresse d'un serveur lié (PUT /api/peers/:id) :
// celle qu'un appareil a transmise n'est pas forcément joignable d'ici.
func UpdatePeerServer(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	id, err := strconv.Atoi(ps.ByName("id"))
	var body updatePeerBody
	if err != nil || json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&body) != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	peerURL, ok := normalizeServerURL(body.URL)
	if !ok {
		writeJSONError(w, http.StatusBadRequest, "Adresse invalide")
		return
	}
	res, err := database.DB.Exec(`UPDATE peer_servers SET url = ?, last_error = '' WHERE id = ?`, peerURL, id)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONError(w, http.StatusNotFound, "Serveur introuvable")
		return
	}
	resetPeerBackoff(id)
	wakeFederation()
	writePeer(w, id)
}

// RemovePeerServer refuse ou retire la paire (DELETE /api/peers/:id), avec les
// liens de comptes qui en dépendent. L'historique déjà partagé reste.
func RemovePeerServer(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid id")
		return
	}
	peer, err := scanPeer(database.DB.QueryRow(`SELECT `+peerColumns+` FROM peer_servers WHERE id = ?`, id))
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "Serveur introuvable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	_, _ = peerCall(ctx, peer, "/api/federation/forget", struct{}{}, nil)
	if _, err := database.DB.Exec(`DELETE FROM peer_servers WHERE id = ?`, id); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status":"ok"}`))
}

// ==================== TRANSMISSION ====================

type peerBackoff struct {
	failures int
	retryAt  time.Time
}

var peerBackoffs = map[int]*peerBackoff{}
var peerBackoffWake = make(chan int, 16)

func resetPeerBackoff(id int) {
	select {
	case peerBackoffWake <- id:
	default:
	}
}

// RunFederation transmet la progression aux serveurs liés jusqu'à l'arrêt du
// contexte. Chaque passe reprend là où la précédente s'est arrêtée
// (account_links.pushed_seq) : un serveur injoignable pendant une semaine
// reçoit tout à son retour, sans file d'attente à entretenir.
func RunFederation(ctx context.Context) {
	ticker := time.NewTicker(federationTick)
	defer ticker.Stop()
	for {
		federationPass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-federationWake:
		case id := <-peerBackoffWake:
			delete(peerBackoffs, id)
		}
	}
}

func peerFailed(peer peerRow, err error) {
	b := peerBackoffs[peer.id]
	if b == nil {
		b = &peerBackoff{}
		peerBackoffs[peer.id] = b
	}
	b.failures++
	delay := federationTick << min(b.failures, 6) // jusqu'à ~5 min
	b.retryAt = time.Now().Add(delay)
	_, _ = database.DB.Exec(`UPDATE peer_servers SET last_error = ? WHERE id = ?`, err.Error(), peer.id)
}

func peerSucceeded(peer peerRow) {
	delete(peerBackoffs, peer.id)
	_, _ = database.DB.Exec(`UPDATE peer_servers SET last_error = '', last_contact_at = CURRENT_TIMESTAMP
		WHERE id = ? AND (last_error != '' OR last_contact_at IS NULL OR last_contact_at < datetime('now', '-1 minute'))`, peer.id)
}

func queryPeers(where string) []peerRow {
	rows, err := database.DB.Query(`SELECT ` + peerColumns + ` FROM peer_servers WHERE ` + where)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var peers []peerRow
	for rows.Next() {
		if p, err := scanPeer(rows); err == nil {
			peers = append(peers, p)
		}
	}
	return peers
}

func federationPass(ctx context.Context) {
	if database.DB == nil {
		return
	}
	now := time.Now()
	for _, peer := range queryPeers(`local_approved = 1 AND approval_sent = 0`) {
		if b := peerBackoffs[peer.id]; b != nil && now.Before(b.retryAt) {
			continue
		}
		status, err := peerCall(ctx, peer, "/api/federation/approval", struct{}{}, nil)
		if err != nil {
			if status == http.StatusUnauthorized {
				err = errors.New("L’autre serveur ne connaît pas ce lien : un compte doit être lié de nouveau")
			}
			peerFailed(peer, err)
			continue
		}
		_, _ = database.DB.Exec(`UPDATE peer_servers SET approval_sent = 1 WHERE id = ?`, peer.id)
		peerSucceeded(peer)
	}
	for _, peer := range queryPeers(`local_approved = 1 AND remote_approved = 1`) {
		if b := peerBackoffs[peer.id]; b != nil && now.Before(b.retryAt) {
			continue
		}
		if err := pushPeer(ctx, peer); err != nil {
			peerFailed(peer, err)
		} else {
			peerSucceeded(peer)
		}
	}
}

type linkRow struct {
	id, userID, remoteUserID, pushedSeq int
}

func pushPeer(ctx context.Context, peer peerRow) error {
	rows, err := database.DB.Query(`SELECT l.id, l.user_id, l.remote_user_id, l.pushed_seq FROM account_links l
		WHERE l.peer_id = ? AND EXISTS (SELECT 1 FROM progress_changes c WHERE c.user_id = l.user_id AND c.seq > l.pushed_seq)`, peer.id)
	if err != nil {
		return err
	}
	var links []linkRow
	for rows.Next() {
		var l linkRow
		if rows.Scan(&l.id, &l.userID, &l.remoteUserID, &l.pushedSeq) == nil {
			links = append(links, l)
		}
	}
	rows.Close()
	for _, link := range links {
		if err := pushLink(ctx, peer, link); err != nil {
			return err
		}
	}
	return nil
}

// pendingChanges lit les progressions modifiées après seq, dans l'ordre. Les
// médias sans identité portable avancent le curseur sans être transmis.
func pendingChanges(userID, after int) (entries []PortableProgress, lastSeq int, read int, err error) {
	rows, err := database.DB.Query(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
		SELECT c.seq, ct.type, ct.tmdb, ct.season, ct.episode,
			p.current_position_seconds, p.is_finished, p.updated_at
		FROM progress_changes c
		LEFT JOIN progressions p ON p.user_id = c.user_id AND p.media_id = c.media_id
		LEFT JOIN content ct ON ct.id = c.media_id
		WHERE c.user_id = ? AND c.seq > ? ORDER BY c.seq LIMIT ?`, userID, after, federationBatch)
	if err != nil {
		return nil, after, 0, err
	}
	defer rows.Close()
	lastSeq = after
	entries = []PortableProgress{}
	for rows.Next() {
		var seq int
		var kind sql.NullString
		var tmdb, season, episode, position sql.NullInt64
		var finished sql.NullBool
		var stamp sql.NullString
		if err := rows.Scan(&seq, &kind, &tmdb, &season, &episode, &position, &finished, &stamp); err != nil {
			return nil, after, 0, err
		}
		read++
		lastSeq = seq
		date := scanSQLiteTime(stamp)
		if !kind.Valid || !position.Valid || date.IsZero() {
			continue
		}
		entries = append(entries, PortableProgress{
			Type: kind.String, TMDBID: int(tmdb.Int64), Season: int(season.Int64), Episode: int(episode.Int64),
			Position: int(position.Int64), Finished: finished.Bool, UpdatedAt: date.UTC().Format(time.RFC3339Nano),
		})
	}
	return entries, lastSeq, read, rows.Err()
}

func pushLink(ctx context.Context, peer peerRow, link linkRow) error {
	for {
		entries, lastSeq, read, err := pendingChanges(link.userID, link.pushedSeq)
		if err != nil || read == 0 {
			return err
		}
		if len(entries) > 0 {
			status, err := peerCall(ctx, peer, "/api/federation/progress", peerProgressBody{
				FromUserID: link.userID, ToUserID: link.remoteUserID, Entries: entries,
			}, nil)
			switch {
			case status == http.StatusNotFound:
				// L'autre serveur ne connaît plus ce lien : dissocié là-bas, ou
				// compte supprimé. Il n'y a plus rien à transmettre.
				_, _ = database.DB.Exec(`DELETE FROM account_links WHERE id = ?`, link.id)
				return nil
			case status == http.StatusUnauthorized:
				_, _ = database.DB.Exec(`UPDATE peer_servers SET remote_approved = 0 WHERE id = ?`, peer.id)
				return errors.New("L’autre serveur ne reconnaît plus ce lien")
			case status == http.StatusForbidden:
				_, _ = database.DB.Exec(`UPDATE peer_servers SET remote_approved = 0 WHERE id = ?`, peer.id)
				return errors.New("En attente de l’administrateur de l’autre serveur")
			case err != nil:
				return err
			}
		}
		if _, err := database.DB.Exec(`UPDATE account_links SET pushed_seq = ? WHERE id = ?`, lastSeq, link.id); err != nil {
			return err
		}
		link.pushedSeq = lastSeq
		if read < federationBatch {
			return nil
		}
	}
}
