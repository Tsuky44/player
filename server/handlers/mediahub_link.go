package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"project-player/server/config"
	"project-player/server/httpx"

	"github.com/julienschmidt/httprouter"
)

// Le test de la liaison avec OnyxHub (ADR-0072).
//
// Seul le serveur peut dire s'il joint OnyxHub : l'app ou le navigateur de
// l'admin ne sont pas sur le même réseau, et une adresse qui marche depuis un
// téléphone (un domaine public) peut être injoignable depuis un conteneur, et
// inversement (un nom Docker). Avant ce test, une adresse fausse ne se
// remarquait qu'à la première demande refusée.

type mediaHubLinkRequest struct {
	// Les valeurs du formulaire, pas encore enregistrées. Absentes ou vides :
	// celles des réglages.
	MediaHubURL    *string `json:"mediahub_url"`
	MediaHubAPIKey *string `json:"mediahub_api_key"`
}

type mediaHubLinkResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	// Service vaut "onyxhub" ou "mediahub" quand l'adresse a répondu comme l'un d'eux.
	Service string `json:"service,omitempty"`
	Version string `json:"version,omitempty"`
}

type integrationPing struct {
	Status  string `json:"status"`
	Service string `json:"service"`
	Version string `json:"version"`
}

// probeMediaHub interroge GET /api/integration/ping, la route d'OnyxHub qui
// n'accepte que la clé d'intégration. MediaHub ne l'a pas : sur un 404, sa
// route de disponibilité (qu'il servait sans clé) dit au moins que l'adresse
// est la bonne.
func probeMediaHub(baseURL, apiKey string, client *http.Client) mediaHubLinkResult {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	apiKey = strings.TrimSpace(apiKey)
	if baseURL == "" {
		return mediaHubLinkResult{Message: "Aucune adresse OnyxHub n'est enregistrée."}
	}
	if apiKey == "" {
		return mediaHubLinkResult{Message: "Aucune clé d'intégration n'est enregistrée."}
	}

	status, body, err := getWithKey(client, baseURL+"/api/integration/ping", apiKey)
	if err != nil {
		return mediaHubLinkResult{Message: "Le serveur ne joint pas cette adresse."}
	}
	switch {
	case status == http.StatusOK:
		var ping integrationPing
		if json.Unmarshal(body, &ping) != nil || ping.Status != "ok" {
			return mediaHubLinkResult{Message: "Cette adresse répond, mais pas comme OnyxHub."}
		}
		message := "OnyxHub répond et accepte la clé."
		if ping.Version != "" {
			message = fmt.Sprintf("OnyxHub %s répond et accepte la clé.", ping.Version)
		}
		return mediaHubLinkResult{OK: true, Message: message, Service: ping.Service, Version: ping.Version}
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return mediaHubLinkResult{Message: "OnyxHub répond, mais refuse cette clé.", Service: "onyxhub"}
	case status == http.StatusNotFound:
		legacy, _, err := getWithKey(client, baseURL+"/api/media/availability/550?type=movie", apiKey)
		if err == nil && legacy == http.StatusOK {
			return mediaHubLinkResult{OK: true, Message: "MediaHub répond (il ne permet pas de vérifier la clé).", Service: "mediahub"}
		}
		return mediaHubLinkResult{Message: "Cette adresse répond, mais ni comme OnyxHub ni comme MediaHub."}
	default:
		return mediaHubLinkResult{Message: fmt.Sprintf("Réponse inattendue de cette adresse (HTTP %d).", status)}
	}
}

func getWithKey(client *http.Client, target, apiKey string) (int, []byte, error) {
	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// TestMediaHubLink teste la liaison avec OnyxHub (POST /api/settings/mediahub/test).
// Le résultat du test n'est pas une erreur HTTP : la réponse est 200 avec
// ok à false et le message à montrer.
func TestMediaHubLink(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	var req mediaHubLinkRequest
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	baseURL := config.MediaHubURL()
	if req.MediaHubURL != nil && strings.TrimSpace(*req.MediaHubURL) != "" {
		baseURL = *req.MediaHubURL
	}
	apiKey := config.MediaHubAPIKey()
	if req.MediaHubAPIKey != nil && strings.TrimSpace(*req.MediaHubAPIKey) != "" {
		apiKey = *req.MediaHubAPIKey
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(probeMediaHub(baseURL, apiKey, httpx.Standard))
}
