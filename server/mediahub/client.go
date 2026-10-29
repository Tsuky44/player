// Package mediahub est le client d'Onyx vers son compagnon de demandes
// (ADR-0089) : MediaHub par son API d'intégration v1, ou OnyxHub, l'ancien
// compagnon, par ses routes d'origine (ADR-0072 à 0077). L'appelant ne voit
// qu'un Client ; le dialecte se reconnaît au premier appel et se retient.
package mediahub

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// V1Path est la base de l'API d'intégration v1 de MediaHub.
const V1Path = "/api/integrations/player/v1"

// maxResponseSize borne ce qu'on lit d'une réponse : une page de demandes
// tient en quelques dizaines de Ko.
const maxResponseSize = 8 << 20

var (
	// ErrNotConfigured : pas d'adresse ou pas de clé dans les réglages.
	ErrNotConfigured = errors.New("mediahub: not configured")
	// ErrUnreachable : l'adresse ne répond pas.
	ErrUnreachable = errors.New("mediahub: unreachable")
	// ErrUnsupported : le compagnon en face (OnyxHub) n'a pas cette fonction.
	ErrUnsupported = errors.New("mediahub: unsupported by this companion")
)

// StatusError est une réponse non 2xx du compagnon. Body est relayé à l'app :
// MediaHub y met { error, code } en français.
type StatusError struct {
	Status int
	Body   []byte
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("mediahub: HTTP %d", e.Status)
}

// Account est le compte Onyx au nom duquel un appel est fait. Le zéro est un
// appel du serveur lui-même (disponibilités).
type Account struct {
	ID       int
	Username string
}

// Client parle au compagnon réglé dans Onyx. HTTP choisit l'échéance.
type Client struct {
	BaseURL string
	APIKey  string
	HTTP    *http.Client
}

func (c Client) base() string { return strings.TrimRight(strings.TrimSpace(c.BaseURL), "/") }
func (c Client) key() string  { return strings.TrimSpace(c.APIKey) }

// Configured dit si l'adresse et la clé sont réglées.
func (c Client) Configured() bool { return c.base() != "" && c.key() != "" }

// do envoie un appel et rend le statut et le corps. Une erreur n'est rendue
// que si l'appel n'a pas abouti.
func (c Client) do(ctx context.Context, method, path string, as Account, query url.Values, body []byte) (int, []byte, error) {
	if !c.Configured() {
		return 0, nil, ErrNotConfigured
	}
	target := c.base() + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return 0, nil, fmt.Errorf("mediahub: build %s %s: %w", method, path, err)
	}
	req.Header.Set("Authorization", "Bearer "+c.key())
	if as.Username != "" {
		req.Header.Set("X-Player-Username", as.Username)
	}
	// L'id du compte Onyx est le lien stable : MediaHub y rattache le compte
	// connecté avec Onyx (ADR-0090), OnyxHub ses demandes (ADR-0075).
	if as.ID > 0 {
		req.Header.Set("X-Player-Id", strconv.Itoa(as.ID))
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return 0, nil, fmt.Errorf("%w: read body: %v", ErrUnreachable, err)
	}
	return resp.StatusCode, raw, nil
}

// call est do, avec un statut hors 2xx rendu en *StatusError.
func (c Client) call(ctx context.Context, method, path string, as Account, query url.Values, body []byte) ([]byte, error) {
	status, raw, err := c.do(ctx, method, path, as, query, body)
	if err != nil {
		return nil, err
	}
	if status < 200 || status > 299 {
		return nil, &StatusError{Status: status, Body: raw}
	}
	return raw, nil
}
