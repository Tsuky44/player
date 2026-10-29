package mediahub

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// CreateRequest relaie une demande de l'app telle quelle : le corps
// (tmdbId, mediaType, title, posterPath, seasons) est le même pour les deux
// compagnons. Le statut et le corps de la réponse reviennent à l'app.
func (c Client) CreateRequest(ctx context.Context, as Account, body []byte) (int, []byte, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return 0, nil, err
	}
	path := "/api/request"
	if dialect == DialectV1 {
		path = V1Path + "/requests"
	}
	return c.do(ctx, http.MethodPost, path, as, nil, body)
}

// Scope choisit les demandes d'une liste.
type Scope string

const (
	// ScopeMine : les demandes du compte.
	ScopeMine Scope = "mine"
	// ScopeAll : celles de tous les comptes, pour qui a read MediaRequest.
	ScopeAll Scope = "all"
)

// requestPages borne la lecture d'une liste : trois pages de cent lignes
// couvrent des mois de demandes, et l'écran ne fait pas défiler plus loin.
const (
	requestPageSize = 100
	requestPages    = 3
)

// Requests rend les demandes en lots, les plus récentes d'abord.
func (c Client) Requests(ctx context.Context, as Account, scope Scope) ([]Lot, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return nil, err
	}
	if dialect == DialectOnyxHub {
		if scope != ScopeMine {
			return nil, ErrUnsupported
		}
		raw, err := c.call(ctx, http.MethodGet, "/api/request", as, nil, nil)
		if err != nil {
			return nil, err
		}
		var legacy struct {
			Requests []Lot `json:"requests"`
		}
		if err := json.Unmarshal(raw, &legacy); err != nil {
			return nil, fmt.Errorf("mediahub: decode onyxhub requests: %w", err)
		}
		return normalizeLegacyLots(legacy.Requests), nil
	}

	var rows []Request
	query := url.Values{"scope": {string(scope)}, "limit": {strconv.Itoa(requestPageSize)}}
	for page := 0; page < requestPages; page++ {
		raw, err := c.call(ctx, http.MethodGet, V1Path+"/requests", as, query, nil)
		if err != nil {
			return nil, err
		}
		var list requestList
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, fmt.Errorf("mediahub: decode requests: %w", err)
		}
		rows = append(rows, list.Requests...)
		if list.NextBefore == nil {
			break
		}
		query.Set("before", strconv.Itoa(*list.NextBefore))
	}
	return GroupLots(rows), nil
}

// FeedEntry est une nouvelle demande pour la notification d'un administrateur
// (ADR-0077). Le format est celui que l'app lit depuis OnyxHub.
type FeedEntry struct {
	ID          int     `json:"id"`
	MediaType   string  `json:"mediaType"`
	TMDBID      int     `json:"tmdbId"`
	Title       string  `json:"title"`
	PosterPath  *string `json:"posterPath"`
	Seasons     []int   `json:"seasons"`
	Requester   string  `json:"requester"`
	RequestedAt string  `json:"requestedAt"`
}

// Feed est une page du flux : Cursor est à repasser au passage suivant.
type Feed struct {
	Cursor   int         `json:"cursor"`
	Requests []FeedEntry `json:"requests"`
}

// Feed rend les demandes faites depuis after (nil : seulement le curseur
// courant), les plus anciennes d'abord, sans celles du compte qui lit.
func (c Client) Feed(ctx context.Context, as Account, after *int) (Feed, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return Feed{}, err
	}
	query := url.Values{}
	if after != nil {
		query.Set("after", strconv.Itoa(*after))
	}
	if dialect == DialectOnyxHub {
		raw, err := c.call(ctx, http.MethodGet, "/api/request/feed", as, query, nil)
		if err != nil {
			return Feed{}, err
		}
		var feed Feed
		if err := json.Unmarshal(raw, &feed); err != nil {
			return Feed{}, fmt.Errorf("mediahub: decode onyxhub feed: %w", err)
		}
		for i := range feed.Requests {
			if feed.Requests[i].Seasons == nil {
				feed.Requests[i].Seasons = []int{}
			}
		}
		if feed.Requests == nil {
			feed.Requests = []FeedEntry{}
		}
		return feed, nil
	}

	raw, err := c.call(ctx, http.MethodGet, V1Path+"/requests/feed", as, query, nil)
	if err != nil {
		return Feed{}, err
	}
	var page requestFeed
	if err := json.Unmarshal(raw, &page); err != nil {
		return Feed{}, fmt.Errorf("mediahub: decode feed: %w", err)
	}
	return Feed{Cursor: page.Cursor, Requests: feedEntries(page.Requests, as.Username)}, nil
}

// feedEntries fait des lignes du flux une notification par geste : les
// saisons d'une série demandées d'un coup arrivent en lignes consécutives du
// même compte. Les demandes du compte qui lit ne le notifient pas (OnyxHub
// les écartait lui-même).
func feedEntries(rows []Request, reader string) []FeedEntry {
	entries := []FeedEntry{}
	for _, row := range rows {
		if reader != "" && strings.EqualFold(row.Requester, reader) {
			continue
		}
		if n := len(entries); n > 0 {
			last := &entries[n-1]
			if last.TMDBID == row.TMDBID && last.MediaType == row.MediaType &&
				strings.EqualFold(last.Requester, row.Requester) && row.MediaType == "tv" {
				last.Seasons = append(last.Seasons, row.Seasons...)
				continue
			}
		}
		seasons := append([]int{}, row.Seasons...)
		entries = append(entries, FeedEntry{
			ID:          row.ID,
			MediaType:   row.MediaType,
			TMDBID:      row.TMDBID,
			Title:       row.Title,
			PosterPath:  row.PosterPath,
			Seasons:     seasons,
			Requester:   row.Requester,
			RequestedAt: row.RequestedAt,
		})
	}
	return entries
}

// Action est une décision de modération.
type Action string

const (
	ActionApprove Action = "approve"
	ActionDecline Action = "decline"
	ActionDelete  Action = "delete"
)

// Valid dit si l'action est connue.
func (a Action) Valid() bool {
	return a == ActionApprove || a == ActionDecline || a == ActionDelete
}

type moderation struct {
	Action Action `json:"action"`
	Reason string `json:"reason,omitempty"`
}

// Moderate applique une décision à chaque ligne d'un lot, au nom du compte :
// MediaHub juge du droit (update ou delete MediaRequest). La première ligne
// refusée arrête le lot et rend son erreur.
func (c Client) Moderate(ctx context.Context, as Account, ids []int, action Action, reason string) error {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return err
	}
	if dialect != DialectV1 {
		return ErrUnsupported
	}
	var body []byte
	if action != ActionDelete {
		body, err = json.Marshal(moderation{Action: action, Reason: strings.TrimSpace(reason)})
		if err != nil {
			return fmt.Errorf("mediahub: encode moderation: %w", err)
		}
	}
	for _, id := range ids {
		path := V1Path + "/requests/" + strconv.Itoa(id)
		method := http.MethodPatch
		if action == ActionDelete {
			method = http.MethodDelete
		}
		if _, err := c.call(ctx, method, path, as, nil, body); err != nil {
			return err
		}
	}
	return nil
}

// Access dit ce que le compte peut faire chez le compagnon.
type Access struct {
	// Service vaut "mediahub" ou "onyxhub".
	Service string `json:"service"`
	Version string `json:"version,omitempty"`
	// Linked : un compte MediaHub porte le nom du compte Onyx. Sans lui,
	// MediaHub prête les droits d'un compte sans rôle, sans demandes à lui.
	Linked bool      `json:"linked"`
	Can    Abilities `json:"can"`
}

// Access lit les droits du compte (le ping de MediaHub, fait en son nom).
// OnyxHub ne connaît que demander et lire ses demandes.
func (c Client) Access(ctx context.Context, as Account) (Access, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return Access{}, err
	}
	if dialect == DialectOnyxHub {
		return Access{Service: DialectOnyxHub.String(), Linked: true, Can: Abilities{Read: true, Request: true}}, nil
	}
	ping, err := c.Ping(ctx, as)
	if err != nil {
		return Access{}, err
	}
	access := Access{Service: DialectV1.String(), Version: ping.Version}
	if ping.User != nil {
		access.Linked = ping.User.Linked
		access.Can = ping.User.Can
	}
	return access, nil
}

// Ping appelle GET {V1Path}/ping au nom du compte.
func (c Client) Ping(ctx context.Context, as Account) (Ping, error) {
	raw, err := c.call(ctx, http.MethodGet, V1Path+"/ping", as, nil, nil)
	if err != nil {
		return Ping{}, err
	}
	var ping Ping
	if err := json.Unmarshal(raw, &ping); err != nil {
		return Ping{}, fmt.Errorf("mediahub: decode ping: %w", err)
	}
	return ping, nil
}
