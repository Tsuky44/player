package mediahub

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Ouvrir MediaHub déjà connecté depuis l'app Onyx (ADR-0090). Onyx tire un
// code court pour le compte connecté ; le navigateur le porte jusqu'à
// MediaHub, qui le rachète auprès d'Onyx, serveur à serveur, avec la clé
// d'intégration. Le code est opaque : MediaHub n'a ni signature à vérifier ni
// liste anti-rejeu à tenir, c'est Onyx qui le consomme au rachat.

// SSOPath est la route de MediaHub où le navigateur atterrit avec le code.
const SSOPath = "/api/auth/onyx/sso"

// SSOTTL : le temps d'ouvrir le navigateur. Le code passe par une URL, donc
// par l'historique : il ne doit plus rien valoir quand on le relit.
const SSOTTL = 60 * time.Second

// SSOMaxPending borne la mémoire : il faut une session Onyx pour tirer un
// code, mais une session suffit à en tirer en boucle.
const SSOMaxPending = 1024

// SSOTicket est la réponse d'Onyx à l'app qui veut ouvrir MediaHub.
type SSOTicket struct {
	URL       string `json:"url"`
	ExpiresIn int    `json:"expires_in"`
}

// SSORedeemRequest est le corps du rachat par MediaHub.
type SSORedeemRequest struct {
	Code string `json:"code"`
}

// SSOURL rend l'adresse d'atterrissage chez MediaHub pour ce code.
func SSOURL(base, code string) string {
	return strings.TrimRight(strings.TrimSpace(base), "/") + SSOPath + "?" + url.Values{"code": {code}}.Encode()
}

// VerifyKey dit si l'appel présente la clé d'intégration en Bearer.
func VerifyKey(header http.Header, key string) error {
	key = strings.TrimSpace(key)
	presented := strings.TrimSpace(strings.TrimPrefix(header.Get("Authorization"), "Bearer "))
	if key == "" || presented == "" || subtle.ConstantTimeCompare([]byte(key), []byte(presented)) != 1 {
		return ErrBadKey
	}
	return nil
}

type ssoEntry struct {
	userID int
	until  time.Time
}

// SSOCodes garde les codes tirés et pas encore rachetés.
type SSOCodes struct {
	mu      sync.Mutex
	ttl     time.Duration
	max     int
	pending map[string]ssoEntry
	now     func() time.Time
}

// NewSSOCodes rend un registre vide.
func NewSSOCodes(ttl time.Duration, max int) *SSOCodes {
	return &SSOCodes{ttl: ttl, max: max, pending: map[string]ssoEntry{}, now: time.Now}
}

// Issue tire un code pour le compte.
func (s *SSOCodes) Issue(userID int) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("mediahub: sso code: %w", err)
	}
	code := hex.EncodeToString(raw)

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.sweep(now)
	if len(s.pending) >= s.max {
		// Le plus proche de l'expiration part : c'est aussi le plus vieux.
		var oldest string
		for k, e := range s.pending {
			if oldest == "" || e.until.Before(s.pending[oldest].until) {
				oldest = k
			}
		}
		delete(s.pending, oldest)
	}
	s.pending[code] = ssoEntry{userID: userID, until: now.Add(s.ttl)}
	return code, nil
}

// Redeem consomme le code et rend son compte. false : inconnu, expiré ou
// déjà racheté. Lire et effacer se font sous le même verrou, sinon deux
// rachats simultanés passeraient tous les deux.
func (s *SSOCodes) Redeem(code string) (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.pending[code]
	if !ok {
		return 0, false
	}
	delete(s.pending, code)
	if !s.now().Before(entry.until) {
		return 0, false
	}
	return entry.userID, true
}

func (s *SSOCodes) sweep(now time.Time) {
	for k, e := range s.pending {
		if !now.Before(e.until) {
			delete(s.pending, k)
		}
	}
}
