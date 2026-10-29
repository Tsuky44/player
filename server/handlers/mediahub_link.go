package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"project-player/server/config"
	"project-player/server/httpx"
	"project-player/server/mediahub"

	"github.com/julienschmidt/httprouter"
)

// Le test de la liaison avec le compagnon de demandes (ADR-0072, 0087).
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
	// Notes sont les réserves d'une liaison qui marche, prêtes à afficher :
	// le compte de l'administrateur absent de MediaHub, ses notifications
	// sans adresse (MediaHub v1 seulement).
	Notes []string `json:"notes,omitempty"`
}

type integrationPing struct {
	Status  string `json:"status"`
	Service string `json:"service"`
	Version string `json:"version"`
}

// probeMediaHub essaie d'abord le ping de l'API v1 de MediaHub, qui vérifie
// la clé et dit ce que vaut le compte de l'administrateur. Un 404 dit un
// compagnon plus ancien : on retombe sur la sonde d'OnyxHub.
func probeMediaHub(baseURL, apiKey string, as mediahub.Account, client *http.Client) mediaHubLinkResult {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	apiKey = strings.TrimSpace(apiKey)
	if baseURL == "" {
		return mediaHubLinkResult{Message: "Aucune adresse MediaHub n'est enregistrée."}
	}
	if apiKey == "" {
		return mediaHubLinkResult{Message: "Aucune clé d'intégration n'est enregistrée."}
	}

	hub := mediahub.Client{BaseURL: baseURL, APIKey: apiKey, HTTP: client}
	ping, err := hub.Ping(context.Background(), as)
	var status *mediahub.StatusError
	switch {
	case err == nil && ping.Status == "ok":
		hub.Remember(mediahub.DialectV1)
		return mediaHubV1LinkResult(ping, as)
	case errors.As(err, &status) && (status.Status == http.StatusUnauthorized || status.Status == http.StatusForbidden):
		hub.Remember(mediahub.DialectV1)
		return mediaHubLinkResult{Message: "MediaHub répond, mais refuse cette clé.", Service: "mediahub"}
	case errors.As(err, &status) && (status.Status == http.StatusNotFound || status.Status == http.StatusMethodNotAllowed):
		result := probeOnyxHub(baseURL, apiKey, client)
		if result.OK {
			hub.Remember(mediahub.DialectOnyxHub)
		}
		return result
	case errors.As(err, &status):
		return mediaHubLinkResult{Message: fmt.Sprintf("Réponse inattendue de cette adresse (HTTP %d).", status.Status)}
	case err == nil:
		return mediaHubLinkResult{Message: "Cette adresse répond, mais pas comme MediaHub."}
	default:
		return mediaHubLinkResult{Message: "Le serveur ne joint pas cette adresse."}
	}
}

// mediaHubV1LinkResult dit ce qui marche, puis ce qui manque encore.
func mediaHubV1LinkResult(ping mediahub.Ping, as mediahub.Account) mediaHubLinkResult {
	message := "MediaHub répond et accepte la clé."
	if ping.Version != "" {
		message = fmt.Sprintf("MediaHub %s répond et accepte la clé.", ping.Version)
	}
	var notes []string
	if as.Username != "" && (ping.User == nil || !ping.User.Linked) {
		notes = append(notes, fmt.Sprintf("Aucun compte MediaHub ne s'appelle « %s » : MediaHub retrouve chaque compte "+
			"d'Onyx par son nom, et un nom inconnu peut demander sans retrouver ses demandes.", as.Username))
	}
	if !ping.WebhookConfigured {
		notes = append(notes, "MediaHub n'envoie pas ses évènements à Onyx : réglez ONYX_WEBHOOK_URL sur "+
			"l'adresse d'Onyx suivie de /api/integrations/mediahub/events pour que les imports s'indexent tout de suite.")
	}
	return mediaHubLinkResult{OK: true, Message: message, Service: ping.Service, Version: ping.Version, Notes: notes}
}

// probeOnyxHub interroge GET /api/integration/ping, la route d'OnyxHub qui
// n'accepte que la clé d'intégration. MediaHub ne l'a pas : sur un 404, sa
// route de disponibilité (qu'il servait sans clé) dit au moins que l'adresse
// est la bonne.
func probeOnyxHub(baseURL, apiKey string, client *http.Client) mediaHubLinkResult {
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

// TestMediaHubLink teste la liaison avec le compagnon (POST /api/settings/mediahub/test),
// au nom de l'administrateur qui la teste. Le résultat du test n'est pas une
// erreur HTTP : la réponse est 200 avec ok à false et le message à montrer.
func TestMediaHubLink(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
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
	// Sans compte lisible, le test vaut quand même pour l'adresse et la clé.
	account, _ := mediaHubAccount(userID)
	_ = json.NewEncoder(w).Encode(probeMediaHub(baseURL, apiKey, account, httpx.Standard))
}
