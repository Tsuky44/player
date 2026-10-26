package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/httpx"

	"github.com/julienschmidt/httprouter"
)

const maxMediaHubResponseSize = 8 << 20

var mediaHubHTTPClient = httpx.Long

// Le compagnon de demandes : OnyxHub, ou un ancien MediaHub, réglé par
// mediahub_url et mediahub_api_key (les noms d'origine, gardés pour les
// installations existantes). Les formats échangés sont épinglés par
// contract/onyxhub/ (ADR-0075).

// MediaHubRequest relaie une demande (POST /api/requests → POST {OnyxHub}/api/request).
func MediaHubRequest(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil || !json.Valid(body) {
		writeMediaHubError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	// Drop the cached availability for this title: the request we are about to
	// forward changes it, and a stale "unknown" would re-offer a season the
	// user just asked for.
	var payload struct {
		TMDBID int `json:"tmdbId"`
	}
	if json.Unmarshal(body, &payload) == nil {
		invalidateMediaHubStatus(payload.TMDBID)
	}

	proxyMediaHub(w, r, userID, http.MethodPost, "/api/request", nil, body)
}

// MediaHubMyRequests relaie les demandes du compte et leur progression
// (GET /api/requests/mine → GET {OnyxHub}/api/request, ADR-0073). La réponse
// passe telle quelle : c'est le format d'OnyxHub que l'app lit. MediaHub n'a
// pas cette route ; son 404 ou son 405 arrive à l'app, qui n'affiche alors pas
// l'écran.
func MediaHubMyRequests(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	proxyMediaHub(w, r, userID, http.MethodGet, "/api/request", nil, nil)
}

// MediaHubRequestFeed relaie le flux des nouvelles demandes de tous les
// comptes (GET /api/requests/feed?after= → GET {OnyxHub}/api/request/feed),
// que l'app d'un administrateur relève en tâche de fond pour notifier
// (ADR-0077). Le curseur est un entier rendu par OnyxHub : on ne transmet que
// lui, pas la requête brute de l'app.
func MediaHubRequestFeed(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	query := url.Values{}
	if raw := r.URL.Query().Get("after"); raw != "" {
		after, err := strconv.Atoi(raw)
		if err != nil || after < 0 {
			writeMediaHubError(w, http.StatusBadRequest, "Curseur invalide")
			return
		}
		query.Set("after", strconv.Itoa(after))
	}
	proxyMediaHub(w, r, userID, http.MethodGet, "/api/request/feed", query, nil)
}

// mediaHubAvailability mirrors MediaHub's getMediaAvailability response.
type mediaHubAvailability struct {
	Status  string `json:"status"`
	Seasons []struct {
		SeasonNumber int    `json:"seasonNumber"`
		Status       string `json:"status"`
	} `json:"seasons"`
	// Waiting says why a request has no download yet; nil when nothing waits.
	Waiting *mediaHubWaiting `json:"waiting,omitempty"`
}

// mediaHubWaiting is the reason, in French and ready to show, a request waits
// for a release (OnyxHub fills it from sorraa).
type mediaHubWaiting struct {
	Message       string `json:"message"`
	NextAttemptAt string `json:"nextAttemptAt,omitempty"`
}

// fetchMediaHubAvailability calls MediaHub GET /api/media/availability/:id.
// Returns nil when MediaHub is not configured or the call fails.
//
// client selects the timeout budget: pass tmdbFastClient on screens that used
// to be a local read, mediaHubHTTPClient when the caller can afford to wait.
func fetchMediaHubAvailability(tmdbID int, mediaType string, client *http.Client) *mediaHubAvailability {
	baseURL := strings.TrimRight(strings.TrimSpace(config.MediaHubURL()), "/")
	apiKey := strings.TrimSpace(config.MediaHubAPIKey())
	if baseURL == "" || apiKey == "" {
		return nil
	}

	target := baseURL + "/api/media/availability/" + strconv.Itoa(tmdbID) +
		"?type=" + url.QueryEscape(mediaType)
	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil
	}
	var availability mediaHubAvailability
	if err := json.Unmarshal(body, &availability); err != nil {
		return nil
	}
	if availability.Status == "" {
		availability.Status = "unknown"
	}
	return &availability
}

func proxyMediaHub(w http.ResponseWriter, r *http.Request, userID int, method, path string, query url.Values, body []byte) {
	baseURL := strings.TrimRight(strings.TrimSpace(config.MediaHubURL()), "/")
	apiKey := strings.TrimSpace(config.MediaHubAPIKey())
	if baseURL == "" || apiKey == "" {
		writeMediaHubError(w, http.StatusServiceUnavailable, "OnyxHub n'est pas configuré sur ce serveur")
		return
	}

	username, err := playerUsername(userID)
	if err != nil {
		writeMediaHubError(w, http.StatusUnauthorized, "Player user not found")
		return
	}

	target := baseURL + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}

	request, err := http.NewRequestWithContext(r.Context(), method, target, bytes.NewReader(body))
	if err != nil {
		writeMediaHubError(w, http.StatusBadGateway, "OnyxHub est injoignable")
		return
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("X-Player-Username", username)
	// L'identifiant survit à un renommage du compte : OnyxHub y rattache ses
	// demandes (ADR-0075). MediaHub l'ignore.
	request.Header.Set("X-Player-Id", strconv.Itoa(userID))
	if len(body) > 0 {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := mediaHubHTTPClient.Do(request)
	if err != nil {
		writeMediaHubError(w, http.StatusBadGateway, "OnyxHub ne répond pas")
		return
	}
	defer response.Body.Close()

	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxMediaHubResponseSize))
	if err != nil {
		writeMediaHubError(w, http.StatusBadGateway, "Réponse illisible d'OnyxHub")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(responseBody)
}

func playerUsername(userID int) (string, error) {
	var username string
	err := database.DB.QueryRow("SELECT username FROM users WHERE id = ?", userID).Scan(&username)
	if err == sql.ErrNoRows {
		return "", err
	}
	return username, err
}

func writeMediaHubError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
