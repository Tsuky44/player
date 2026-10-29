package handlers

import (
	"context"
	"errors"
	"log"
	"net/http"

	"project-player/server/mediahub"
)

// Les disponibilités d'une page du catalogue de demandes en un seul appel
// (ADR-0072). MediaHub v1 sert toujours le lot ; un OnyxHub ancien peut ne
// pas l'avoir, et l'appelant retombe alors sur l'appel par carte.

// errorResponse est le corps d'erreur que l'app lit ({ "error": … }).
type errorResponse struct {
	Error string `json:"error"`
}

// availabilityKey identifie un média dans un lot : un film et une série
// peuvent partager le même identifiant TMDB.
func availabilityKey(mediaType string, tmdbID int) string {
	return mediahub.AvailabilityKey(mediaType, tmdbID)
}

// contextBackground : les disponibilités du catalogue ne sont pas liées à la
// requête de l'app, que la page en cache peut avoir déjà servie.
func contextBackground() context.Context { return context.Background() }

// fetchMediaHubAvailabilityBatch rend le statut de chaque média, indexé par
// availabilityKey. supported est faux quand la route n'existe pas en face :
// l'appelant retombe alors sur l'appel par carte. Une autre panne rend
// (nil, true) : les cartes restent sans pastille, comme avec l'appel unitaire.
func fetchMediaHubAvailabilityBatch(items []mediahub.BatchItem, client *http.Client) (statuses map[string]string, supported bool) {
	hub := mediaHubClient(client)
	if !hub.Configured() || len(items) == 0 {
		return nil, true
	}
	statuses, err := hub.AvailabilityBatch(contextBackground(), items)
	if errors.Is(err, mediahub.ErrUnsupported) {
		return nil, false
	}
	if err != nil {
		log.Printf("fetchMediaHubAvailabilityBatch: %v", err)
		return nil, true
	}
	return statuses, true
}
