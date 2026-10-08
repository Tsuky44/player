package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"project-player/server/config"
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
