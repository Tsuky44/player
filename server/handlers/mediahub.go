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
	"time"

	"project-player/server/config"
	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

const maxMediaHubResponseSize = 8 << 20

var mediaHubHTTPClient = &http.Client{Timeout: 30 * time.Second}

func MediaHubCatalog(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	proxyMediaHub(w, r, userID, http.MethodGet, "/api/integrations/player/catalog", r.URL.Query(), nil)
}

func MediaHubDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	mediaID := strings.TrimSpace(ps.ByName("id"))
	if mediaID == "" {
		writeMediaHubError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}
	proxyMediaHub(w, r, userID, http.MethodGet, "/api/integrations/player/media/"+url.PathEscape(mediaID), r.URL.Query(), nil)
}

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

// mediaHubAvailability mirrors MediaHub's getMediaAvailability response.
type mediaHubAvailability struct {
	Status  string `json:"status"`
	Seasons []struct {
		SeasonNumber int    `json:"seasonNumber"`
		Status       string `json:"status"`
	} `json:"seasons"`
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
		writeMediaHubError(w, http.StatusServiceUnavailable, "MediaHub integration is not configured")
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
		writeMediaHubError(w, http.StatusBadGateway, "Unable to contact MediaHub")
		return
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("X-Player-Username", username)
	if len(body) > 0 {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := mediaHubHTTPClient.Do(request)
	if err != nil {
		writeMediaHubError(w, http.StatusBadGateway, "MediaHub is unavailable")
		return
	}
	defer response.Body.Close()

	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxMediaHubResponseSize))
	if err != nil {
		writeMediaHubError(w, http.StatusBadGateway, "Invalid MediaHub response")
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
