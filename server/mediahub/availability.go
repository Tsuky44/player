package mediahub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"sync/atomic"
	"time"
)

// Availability rend la disponibilité d'un titre. Appel du serveur : sans
// compte, MediaHub l'accorde à tous (read Media).
func (c Client) Availability(ctx context.Context, tmdbID int, mediaType string) (*Availability, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return nil, err
	}
	path := "/api/media/availability/" + strconv.Itoa(tmdbID)
	if dialect == DialectV1 {
		path = V1Path + "/availability/" + strconv.Itoa(tmdbID)
	}
	raw, err := c.call(ctx, http.MethodGet, path, Account{}, url.Values{"type": {mediaType}}, nil)
	if err != nil {
		return nil, err
	}
	var availability Availability
	if err := json.Unmarshal(raw, &availability); err != nil {
		return nil, fmt.Errorf("mediahub: decode availability: %w", err)
	}
	if availability.Status == "" {
		availability.Status = "unknown"
	}
	return &availability, nil
}

// MaxBatch est la taille d'un lot que MediaHub accepte.
const MaxBatch = 100

// batchUnsupportedFor : après un 404 ou un 405, l'OnyxHub d'en face n'a pas
// la route du lot ; on ne la redemande qu'après ce délai, pour suivre une mise
// à jour sans payer un appel perdu à chaque page (ADR-0072).
const batchUnsupportedFor = 10 * time.Minute

// batchUnsupportedUntil est l'instant (UnixNano) jusqu'auquel on ne tente pas le lot.
var batchUnsupportedUntil atomic.Int64

// AvailabilityKey identifie un titre dans un lot : un film et une série
// peuvent partager le même identifiant TMDB.
func AvailabilityKey(mediaType string, tmdbID int) string {
	return mediaType + ":" + strconv.Itoa(tmdbID)
}

// AvailabilityBatch rend le statut de chaque titre, indexé par
// AvailabilityKey, en un appel. ErrUnsupported dit qu'il faut retomber sur
// l'appel par titre (un OnyxHub ancien).
func (c Client) AvailabilityBatch(ctx context.Context, items []BatchItem) (map[string]string, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return nil, err
	}
	path := V1Path + "/availability"
	if dialect == DialectOnyxHub {
		if time.Now().UnixNano() < batchUnsupportedUntil.Load() {
			return nil, ErrUnsupported
		}
		path = "/api/media/availability"
	}
	if len(items) > MaxBatch {
		items = items[:MaxBatch]
	}
	body, err := json.Marshal(batchRequest{Items: items})
	if err != nil {
		return nil, fmt.Errorf("mediahub: encode batch: %w", err)
	}
	raw, err := c.call(ctx, http.MethodPost, path, Account{}, nil, body)
	var status *StatusError
	if dialect == DialectOnyxHub && errors.As(err, &status) &&
		(status.Status == http.StatusNotFound || status.Status == http.StatusMethodNotAllowed) {
		batchUnsupportedUntil.Store(time.Now().Add(batchUnsupportedFor).UnixNano())
		return nil, ErrUnsupported
	}
	if err != nil {
		return nil, err
	}
	var decoded batchResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("mediahub: decode batch: %w", err)
	}
	statuses := make(map[string]string, len(decoded.Results))
	for _, result := range decoded.Results {
		if result.Status != "" {
			statuses[AvailabilityKey(result.MediaType, result.TMDBID)] = result.Status
		}
	}
	return statuses, nil
}
