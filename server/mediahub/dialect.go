package mediahub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"
)

// Dialect est la langue que parle le compagnon réglé.
type Dialect int

const (
	// DialectUnknown : l'adresse n'a pas répondu, on ne sait pas encore.
	DialectUnknown Dialect = iota
	// DialectOnyxHub : OnyxHub, ou un MediaHub d'avant l'API v1.
	DialectOnyxHub
	// DialectV1 : MediaHub et son API d'intégration v1.
	DialectV1
)

func (d Dialect) String() string {
	switch d {
	case DialectV1:
		return "mediahub"
	case DialectOnyxHub:
		return "onyxhub"
	default:
		return ""
	}
}

// Un dialecte reconnu se garde dix minutes : assez pour ne pas payer un ping
// par page du catalogue, assez peu pour suivre la mise à jour d'un OnyxHub en
// MediaHub à la même adresse. Une adresse muette se redemande vite.
const (
	dialectKnownFor   = 10 * time.Minute
	dialectUnknownFor = 15 * time.Second
)

type dialectEntry struct {
	dialect Dialect
	until   time.Time
}

var dialects = struct {
	sync.Mutex
	byBase map[string]dialectEntry
}{byBase: map[string]dialectEntry{}}

// Dialect rend le dialecte du compagnon, reconnu par GET {V1Path}/ping : une
// réponse de MediaHub (200, ou 401/403 sur une mauvaise clé) dit la v1, un 404
// dit une route absente, donc OnyxHub.
func (c Client) Dialect(ctx context.Context) Dialect {
	base := c.base()
	dialects.Lock()
	entry, ok := dialects.byBase[base]
	dialects.Unlock()
	if ok && time.Now().Before(entry.until) {
		return entry.dialect
	}

	dialect := c.detect(ctx)
	remember(base, dialect)
	return dialect
}

func (c Client) detect(ctx context.Context) Dialect {
	status, raw, err := c.do(ctx, http.MethodGet, V1Path+"/ping", Account{}, nil, nil)
	if err != nil {
		return DialectUnknown
	}
	switch {
	case status == http.StatusOK:
		var ping Ping
		if json.Unmarshal(raw, &ping) == nil && ping.Status == "ok" {
			return DialectV1
		}
		return DialectOnyxHub
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return DialectV1
	case status == http.StatusNotFound || status == http.StatusMethodNotAllowed:
		return DialectOnyxHub
	default:
		return DialectUnknown
	}
}

func remember(base string, dialect Dialect) {
	ttl := dialectKnownFor
	if dialect == DialectUnknown {
		ttl = dialectUnknownFor
	}
	dialects.Lock()
	dialects.byBase[base] = dialectEntry{dialect: dialect, until: time.Now().Add(ttl)}
	dialects.Unlock()
}

// Remember retient le dialecte qu'un test de liaison vient de constater.
func (c Client) Remember(dialect Dialect) { remember(c.base(), dialect) }

// Reset oublie les dialectes, le délai de grâce du lot et les livraisons
// déjà vues : les tests montent un faux compagnon par test, à des adresses
// qui se réutilisent.
func Reset() {
	dialects.Lock()
	dialects.byBase = map[string]dialectEntry{}
	dialects.Unlock()
	batchUnsupportedUntil.Store(0)
	deliveries = newDeliveries()
}

// dialect rend le dialecte, ou ErrUnreachable quand on ne le connaît pas.
func (c Client) dialect(ctx context.Context) (Dialect, error) {
	if !c.Configured() {
		return DialectUnknown, ErrNotConfigured
	}
	if d := c.Dialect(ctx); d != DialectUnknown {
		return d, nil
	}
	return DialectUnknown, ErrUnreachable
}

// IsUnreachable dit si err vient d'une adresse muette.
func IsUnreachable(err error) bool { return errors.Is(err, ErrUnreachable) }
