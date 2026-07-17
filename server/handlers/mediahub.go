package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

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
	proxyMediaHub(w, r, userID, http.MethodPost, "/api/request", nil, body)
}

func proxyMediaHub(w http.ResponseWriter, r *http.Request, userID int, method, path string, query url.Values, body []byte) {
	baseURL := strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIAHUB_URL")), "/")
	apiKey := strings.TrimSpace(os.Getenv("MEDIAHUB_API_KEY"))
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
