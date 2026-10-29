package mediahub

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"project-player/server/ttlcache"
)

// Les évènements que MediaHub pousse vers Onyx (ADR-0089).

const (
	EventTest          = "webhook.test"
	EventCreated       = "request.created"
	EventStatusChanged = "request.status_changed"
	EventDeleted       = "request.deleted"
	EventImported      = "media.imported"
)

// Event est l'enveloppe d'un évènement.
type Event struct {
	ID         string          `json:"id"`
	Event      string          `json:"event"`
	APIVersion int             `json:"apiVersion"`
	OccurredAt string          `json:"occurredAt"`
	Data       json.RawMessage `json:"data"`
}

// RequestEventData porte request.created, request.status_changed et
// request.deleted.
type RequestEventData struct {
	Request        Request `json:"request"`
	PreviousStatus string  `json:"previousStatus,omitempty"`
	RequesterID    int     `json:"requesterId"`
}

// ImportedData porte media.imported : les chemins sont ceux que Radarr ou
// Sonarr voient, et peuvent manquer.
type ImportedData struct {
	TMDBID    int      `json:"tmdbId"`
	MediaType string   `json:"mediaType"`
	Seasons   []int    `json:"seasons,omitempty"`
	Paths     []string `json:"paths"`
}

// MaxImportPaths : une saison entière tient largement dedans.
const MaxImportPaths = 100

var (
	// ErrBadKey : la clé d'intégration présentée n'est pas celle d'Onyx.
	ErrBadKey = errors.New("mediahub: bad integration key")
	// ErrBadSignature : le corps n'est pas celui que MediaHub a signé.
	ErrBadSignature = errors.New("mediahub: bad signature")
)

// VerifyDelivery vérifie un évènement reçu : la clé d'intégration dans
// Authorization, puis X-MediaHub-Signature, HMAC-SHA256 du corps brut avec la
// même clé. La clé seule dit qui appelle ; la signature dit que le corps n'a
// pas été changé en route (un proxy qui journalise, une réémission).
func VerifyDelivery(header http.Header, body []byte, key string) error {
	if err := VerifyKey(header, key); err != nil {
		return err
	}
	signature, ok := strings.CutPrefix(header.Get("X-MediaHub-Signature"), "sha256=")
	if !ok {
		return ErrBadSignature
	}
	given, err := hex.DecodeString(strings.TrimSpace(signature))
	if err != nil {
		return ErrBadSignature
	}
	if !hmac.Equal(given, Sign(body, key)) {
		return ErrBadSignature
	}
	return nil
}

// Sign rend le HMAC-SHA256 du corps, tel que MediaHub le calcule.
func Sign(body []byte, key string) []byte {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(key)))
	mac.Write(body)
	return mac.Sum(nil)
}

// DecodeEvent lit l'enveloppe.
func DecodeEvent(body []byte) (Event, error) {
	var event Event
	if err := json.Unmarshal(body, &event); err != nil {
		return Event{}, fmt.Errorf("mediahub: decode event: %w", err)
	}
	if event.Event == "" {
		return Event{}, errors.New("mediahub: event without name")
	}
	return event, nil
}

// MediaHub réessaie trois fois en quelques secondes : une heure de mémoire
// suffit pour ne traiter qu'une fois chaque livraison.
var deliveries = newDeliveries()

func newDeliveries() *ttlcache.Cache[bool] { return ttlcache.New[bool](time.Hour, 4096) }

// FirstDelivery dit si cette livraison n'a pas déjà été traitée, et la
// retient. Un identifiant vide passe toujours.
func FirstDelivery(id string) bool {
	if id == "" {
		return true
	}
	if _, seen := deliveries.Get(id); seen {
		return false
	}
	deliveries.Put(id, true)
	return true
}
