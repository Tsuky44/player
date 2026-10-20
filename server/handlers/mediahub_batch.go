package handlers

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"project-player/server/config"
)

// Les disponibilités d'une page du catalogue de demandes en un seul appel
// (ADR-0072).
//
// enrichCatalogAvailability interrogeait la route unitaire une fois par carte :
// vingt appels par page, huit à la fois, chacun relisant côté OnyxHub ce que
// le précédent venait de lire. OnyxHub sert la page entière sur
// POST /api/media/availability. MediaHub et les OnyxHub plus anciens ne
// connaissent pas cette route : on retombe alors sur l'appel par carte.

type availabilityBatchItem struct {
	TMDBID    int    `json:"tmdbId"`
	MediaType string `json:"mediaType"`
}

type availabilityBatchResponse struct {
	Results []struct {
		TMDBID    int    `json:"tmdbId"`
		MediaType string `json:"mediaType"`
		Status    string `json:"status"`
	} `json:"results"`
}

// batchUnsupportedFor : après un 404 ou un 405, le serveur d'en face n'a pas la
// route ; on ne la redemande qu'après ce délai, pour suivre une mise à jour
// d'OnyxHub sans payer un appel perdu à chaque page.
const batchUnsupportedFor = 10 * time.Minute

// batchUnsupportedUntil est l'instant (UnixNano) jusqu'auquel on ne tente pas le lot.
var batchUnsupportedUntil atomic.Int64

// availabilityKey identifie un média dans un lot : un film et une série
// peuvent partager le même identifiant TMDB.
func availabilityKey(mediaType string, tmdbID int) string {
	return mediaType + ":" + strconv.Itoa(tmdbID)
}

// fetchMediaHubAvailabilityBatch rend le statut de chaque média, indexé par
// availabilityKey. supported est faux quand la route n'existe pas en face :
// l'appelant retombe alors sur l'appel par carte. Une autre panne rend
// (nil, true) : les cartes restent sans pastille, comme avec l'appel unitaire.
func fetchMediaHubAvailabilityBatch(items []availabilityBatchItem, client *http.Client) (statuses map[string]string, supported bool) {
	if time.Now().UnixNano() < batchUnsupportedUntil.Load() {
		return nil, false
	}
	baseURL := strings.TrimRight(strings.TrimSpace(config.MediaHubURL()), "/")
	apiKey := strings.TrimSpace(config.MediaHubAPIKey())
	if baseURL == "" || apiKey == "" || len(items) == 0 {
		return nil, true
	}

	body, err := json.Marshal(map[string][]availabilityBatchItem{"items": items})
	if err != nil {
		return nil, true
	}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/api/media/availability", bytes.NewReader(body))
	if err != nil {
		return nil, true
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, true
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusMethodNotAllowed {
		batchUnsupportedUntil.Store(time.Now().Add(batchUnsupportedFor).UnixNano())
		return nil, false
	}
	if resp.StatusCode != http.StatusOK {
		return nil, true
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxMediaHubResponseSize))
	if err != nil {
		return nil, true
	}
	var decoded availabilityBatchResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, true
	}
	statuses = make(map[string]string, len(decoded.Results))
	for _, result := range decoded.Results {
		if result.Status != "" {
			statuses[availabilityKey(result.MediaType, result.TMDBID)] = result.Status
		}
	}
	return statuses, true
}
