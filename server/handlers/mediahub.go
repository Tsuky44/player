package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/mediahub"

	"github.com/julienschmidt/httprouter"
)

var mediaHubHTTPClient = httpx.Long

// Le compagnon de demandes : MediaHub par son API v1, ou OnyxHub tant qu'il
// n'est pas retiré, réglé par mediahub_url et mediahub_api_key. Le dialecte se
// reconnaît dans le package mediahub (ADR-0089) ; les handlers ne voient que
// le client. Les formats échangés sont épinglés par contract/mediahub/ et,
// pour OnyxHub, contract/onyxhub/ (ADR-0075).

// mediaHubAvailability et mediaHubWaiting gardent les noms que lisent les
// écrans du catalogue.
type (
	mediaHubAvailability = mediahub.Availability
	mediaHubWaiting      = mediahub.Waiting
)

// mediaHubClient rend le client réglé, avec l'échéance choisie.
func mediaHubClient(client *http.Client) mediahub.Client {
	return mediahub.Client{BaseURL: config.MediaHubURL(), APIKey: config.MediaHubAPIKey(), HTTP: client}
}

// mediaHubAccount rend le compte Onyx au nom duquel parler. MediaHub retrouve
// son compte par l'id, puis par le nom en repli (ADR-0090).
func mediaHubAccount(userID int) (mediahub.Account, error) {
	username, err := playerUsername(userID)
	if err != nil {
		return mediahub.Account{}, err
	}
	return mediahub.Account{ID: userID, Username: username}, nil
}

// MediaHubRequest relaie une demande (POST /api/requests).
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

	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	status, answer, err := mediaHubClient(mediaHubHTTPClient).CreateRequest(r.Context(), account, body)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubRequest", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(answer)
}

// myRequestsResponse est la liste de « Mes demandes » et de « Toutes les
// demandes », au format d'Onyx (contract/requests_mine.json).
type myRequestsResponse struct {
	Requests []mediahub.Lot `json:"requests"`
}

// MediaHubMyRequests rend les demandes du compte en lots
// (GET /api/requests/mine, ADR-0073 et 0087).
func MediaHubMyRequests(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	serveMediaHubLots(w, r, userID, mediahub.ScopeMine)
}

func serveMediaHubLots(w http.ResponseWriter, r *http.Request, userID int, scope mediahub.Scope) {
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	lots, err := mediaHubClient(mediaHubHTTPClient).Requests(r.Context(), account, scope)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubRequests", err)
		return
	}
	if lots == nil {
		lots = []mediahub.Lot{}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(myRequestsResponse{Requests: lots})
}

// MediaHubRequestFeed rend les nouvelles demandes de tous les comptes
// (GET /api/requests/feed?after=), que l'app d'un administrateur relève en
// tâche de fond pour notifier (ADR-0077). Le curseur est un entier rendu par
// le compagnon : on ne transmet que lui, pas la requête brute de l'app.
func MediaHubRequestFeed(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var after *int
	if raw := r.URL.Query().Get("after"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 {
			writeMediaHubError(w, http.StatusBadRequest, "Curseur invalide")
			return
		}
		after = &value
	}
	account, ok := mediaHubAccountOrFail(w, userID)
	if !ok {
		return
	}
	feed, err := mediaHubClient(mediaHubHTTPClient).Feed(r.Context(), account, after)
	if err != nil {
		writeMediaHubFailure(w, "MediaHubRequestFeed", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(feed)
}

// fetchMediaHubAvailability rend la disponibilité d'un titre, ou nil quand le
// compagnon n'est pas réglé ou que l'appel échoue.
//
// client selects the timeout budget: pass tmdbFastClient on screens that used
// to be a local read, mediaHubHTTPClient when the caller can afford to wait.
func fetchMediaHubAvailability(tmdbID int, mediaType string, client *http.Client) *mediaHubAvailability {
	hub := mediaHubClient(client)
	if !hub.Configured() {
		return nil
	}
	availability, err := hub.Availability(contextBackground(), tmdbID, mediaType)
	if err != nil {
		// Un MediaHub muet se dirait vingt fois par page du catalogue : seule
		// une réponse inattendue mérite le journal.
		if !mediahub.IsUnreachable(err) {
			log.Printf("fetchMediaHubAvailability: %s %d: %v", mediaType, tmdbID, err)
		}
		return nil
	}
	return availability
}

func mediaHubAccountOrFail(w http.ResponseWriter, userID int) (mediahub.Account, bool) {
	account, err := mediaHubAccount(userID)
	if err != nil {
		writeMediaHubError(w, http.StatusUnauthorized, "Player user not found")
		return mediahub.Account{}, false
	}
	return account, true
}

// writeMediaHubFailure traduit une erreur du client pour l'app : la réponse
// du compagnon passe telle quelle (MediaHub y met { error, code }), le reste
// devient un message court. L'app lit 503 comme « pas de compagnon » et 502
// comme une panne passagère (ADR-0077).
func writeMediaHubFailure(w http.ResponseWriter, where string, err error) {
	var status *mediahub.StatusError
	switch {
	case errors.As(err, &status):
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status.Status)
		if json.Valid(status.Body) {
			_, _ = w.Write(status.Body)
		} else {
			_ = json.NewEncoder(w).Encode(errorResponse{Error: "Réponse illisible de MediaHub"})
		}
	case errors.Is(err, mediahub.ErrNotConfigured):
		writeMediaHubError(w, http.StatusServiceUnavailable, "MediaHub n'est pas configuré sur ce serveur")
	case errors.Is(err, mediahub.ErrUnsupported):
		writeMediaHubError(w, http.StatusNotImplemented, "Le compagnon de demandes de ce serveur ne le permet pas")
	default:
		log.Printf("%s: %v", where, err)
		writeMediaHubError(w, http.StatusBadGateway, "MediaHub ne répond pas")
	}
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
	_ = json.NewEncoder(w).Encode(errorResponse{Error: message})
}
