package handlers

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"project-player/server/config"
	"project-player/server/database"
	"strconv"
	"strings"
	"time"

	"github.com/julienschmidt/httprouter"
)

// Routes des serveurs liés : publiques, entre serveurs, et celles du compte.
// Voir federation.go et l'ADR-0017.

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
	json.NewEncoder(w).Encode(linkCodeResponse{
		Code: code, ExpiresIn: int(linkCodeTTL.Seconds()), ServerID: config.ServerID(),
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
