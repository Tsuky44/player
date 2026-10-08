package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"project-player/server/database"
	"strconv"
	"time"

	"github.com/julienschmidt/httprouter"
)

// Routes d'administration des serveurs liés. Voir federation.go.

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
