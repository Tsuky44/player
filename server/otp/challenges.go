package otp

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// MaxAttempts est le nombre de codes qu'on peut essayer sur une même étape.
// Au-delà, l'étape disparaît et il faut retaper le mot de passe : c'est lui,
// et ses limites de débit (ADR-0032), qui bornent les essais sur six chiffres.
const MaxAttempts = 5

// Challenge est une connexion arrêtée entre le mot de passe et le code, ou une
// activation arrêtée entre le QR code et le premier code.
type Challenge struct {
	UserID   int
	Username string
	// Setup : le compte configure son code pendant cette étape.
	Setup bool
	// Secret : le secret proposé, tant qu'il n'est pas enregistré. Vide pour
	// une étape StepCode, dont le secret est déjà en base.
	Secret string

	attempts int
	expires  time.Time
}

// maxChallenges borne la mémoire : au-delà, les étapes expirées sont oubliées,
// puis les plus anciennes si cela ne suffit pas.
const maxChallenges = 10_000

// Challenges garde les étapes en cours, en mémoire : un redémarrage du serveur
// les annule, et il suffit alors de recommencer la connexion.
type Challenges struct {
	mu  sync.Mutex
	m   map[string]*Challenge
	ttl time.Duration
	now func() time.Time
}

// NewChallenges crée un magasin dont les étapes vivent ttl.
func NewChallenges(ttl time.Duration) *Challenges {
	return &Challenges{m: map[string]*Challenge{}, ttl: ttl, now: time.Now}
}

// NewChallengesForTest est NewChallenges avec une horloge imposée.
func NewChallengesForTest(ttl time.Duration, now func() time.Time) *Challenges {
	return &Challenges{m: map[string]*Challenge{}, ttl: ttl, now: now}
}

// Issue ouvre une étape sous un jeton aléatoire, à remettre au client.
func (s *Challenges) Issue(c Challenge) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("otp: generate challenge: %w", err)
	}
	token := hex.EncodeToString(raw)
	s.Put(token, c)
	return token, nil
}

// Put ouvre une étape sous une clé choisie : l'activation depuis les réglages
// se range sous l'identifiant du compte, une seule à la fois.
func (s *Challenges) Put(key string, c Challenge) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if len(s.m) >= maxChallenges {
		for k, existing := range s.m {
			if !now.Before(existing.expires) {
				delete(s.m, k)
			}
		}
		if len(s.m) >= maxChallenges {
			s.m = map[string]*Challenge{}
		}
	}
	c.attempts = 0
	c.expires = now.Add(s.ttl)
	s.m[key] = &c
}

// Attempt compte un essai sur l'étape et la rend. false : l'étape n'existe
// pas, a expiré ou a épuisé ses essais — elle est alors oubliée.
func (s *Challenges) Attempt(key string) (Challenge, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.m[key]
	if !ok {
		return Challenge{}, false
	}
	if !s.now().Before(c.expires) || c.attempts >= MaxAttempts {
		delete(s.m, key)
		return Challenge{}, false
	}
	c.attempts++
	return *c, true
}

// Finish ferme l'étape, réussie ou abandonnée.
func (s *Challenges) Finish(key string) {
	s.mu.Lock()
	delete(s.m, key)
	s.mu.Unlock()
}
