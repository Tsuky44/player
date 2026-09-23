// Package playbackauth owns temporary, revocable media access. Raw bearer
// secrets are returned once to the client; only SHA-256 digests live in memory.
package playbackauth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

const TTL = 15 * time.Minute

var ErrDenied = errors.New("invalid or expired playback ticket")

type Ticket struct {
	UserID       int
	MediaID      int
	ExpiresAt    time.Time
	LastActivity time.Time
}

type Store struct {
	mu      sync.Mutex
	tickets map[[32]byte]Ticket
	now     func() time.Time
	// generation moves on every Renew and Revoke: a GuardWriter that saw the
	// same value can trust what it validated without taking the lock again.
	generation atomic.Uint64
}

func NewStore() *Store             { return &Store{tickets: make(map[[32]byte]Ticket), now: time.Now} }
func Digest(token string) [32]byte { return sha256.Sum256([]byte(token)) }

func (s *Store) Issue(userID, mediaID int) (string, Ticket, error) {
	if userID <= 0 || mediaID <= 0 {
		return "", Ticket{}, ErrDenied
	}
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return "", Ticket{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(secret[:])
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.reapLocked(now)
	count := 0
	for _, ticket := range s.tickets {
		if ticket.UserID == userID {
			count++
		}
	}
	if len(s.tickets) >= 4096 || count >= 32 {
		return "", Ticket{}, errors.New("playback ticket capacity reached")
	}
	ticket := Ticket{UserID: userID, MediaID: mediaID, ExpiresAt: now.Add(TTL), LastActivity: now}
	s.tickets[Digest(token)] = ticket
	return token, ticket, nil
}

func (s *Store) Validate(token string, mediaID int) (Ticket, bool) {
	if len(token) != 43 {
		return Ticket{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := Digest(token)
	ticket, ok := s.tickets[key]
	now := s.now()
	if !ok || !now.Before(ticket.ExpiresAt) {
		delete(s.tickets, key)
		return Ticket{}, false
	}
	if ticket.MediaID != mediaID {
		return Ticket{}, false
	}
	ticket.LastActivity = now
	s.tickets[key] = ticket
	return ticket, true
}

// Only an authenticated owner can extend the deadline; fetching bytes does not.
func (s *Store) Renew(token string, userID int) (Ticket, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := Digest(token)
	ticket, ok := s.tickets[key]
	now := s.now()
	if !ok || ticket.UserID != userID || !now.Before(ticket.ExpiresAt) {
		return Ticket{}, ErrDenied
	}
	ticket.ExpiresAt = now.Add(TTL)
	ticket.LastActivity = now
	s.tickets[key] = ticket
	s.generation.Add(1)
	return ticket, nil
}

func (s *Store) Revoke(token string, userID int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := Digest(token)
	if ticket, ok := s.tickets[key]; ok && ticket.UserID == userID {
		delete(s.tickets, key)
		s.generation.Add(1)
	}
}

// IsLive is for the HLS reaper: it never prolongs user activity and requires no
// raw secret to be retained with a transcoder session.
func (s *Store) IsLive(key [32]byte, mediaID int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	ticket, ok := s.tickets[key]
	return ok && ticket.MediaID == mediaID && s.now().Before(ticket.ExpiresAt)
}

// Holds dit si userID détient un ticket encore valide pour mediaID, c'est-à-
// dire s'il est en train de lire ce média.
func (s *Store) Holds(userID, mediaID int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for _, ticket := range s.tickets {
		if ticket.UserID == userID && ticket.MediaID == mediaID && now.Before(ticket.ExpiresAt) {
			return true
		}
	}
	return false
}

func (s *Store) reapLocked(now time.Time) {
	for key, ticket := range s.tickets {
		if !now.Before(ticket.ExpiresAt) {
			delete(s.tickets, key)
		}
	}
}

func (s *Store) RunReaper(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			s.reapLocked(s.now())
			s.mu.Unlock()
		}
	}
}

// GuardWriter also stops an already-open Range response after revocation or
// expiry. Never delegate to the underlying ReaderFrom (sendfile): every byte
// must pass through Write.
//
// A direct-play stream is thousands of writes a second, and each one used to
// take the store's global lock and hash the token. The writer now keeps what
// it last validated and only goes back to the store when the ticket's deadline
// passes or the store's generation moved (a Renew or a Revoke somewhere) —
// revocation still stops the very next write.
type GuardWriter struct {
	http.ResponseWriter
	Store   *Store
	Token   string
	MediaID int

	validUntil time.Time
	generation uint64
}

func (w *GuardWriter) Write(data []byte) (int, error) {
	if !w.stillValid() {
		return 0, ErrDenied
	}
	return w.ResponseWriter.Write(data)
}

func (w *GuardWriter) stillValid() bool {
	generation := w.Store.generation.Load()
	if generation == w.generation && w.Store.now().Before(w.validUntil) {
		return true
	}
	ticket, ok := w.Store.Validate(w.Token, w.MediaID)
	if !ok {
		return false
	}
	w.validUntil = ticket.ExpiresAt
	w.generation = generation
	return true
}

// copyBufferSize is the chunk a stream goes out in. io.Copy's default is 32 KiB,
// which at 4K-remux rates is several thousand writes — and syscalls — a second.
const copyBufferSize = 256 << 10

var copyBuffers = sync.Pool{New: func() any { b := make([]byte, copyBufferSize); return &b }}

// ReadFrom only picks a larger buffer: every byte still goes through Write,
// and so through the ticket check.
func (w *GuardWriter) ReadFrom(src io.Reader) (int64, error) {
	buf := copyBuffers.Get().(*[]byte)
	defer copyBuffers.Put(buf)
	return io.CopyBuffer(writeOnly{w}, src, *buf)
}

// writeOnly hides ReadFrom from io.CopyBuffer, which would otherwise call
// straight back into it.
type writeOnly struct{ io.Writer }

func Protect(w http.ResponseWriter, r *http.Request, store *Store, mediaID int) (http.ResponseWriter, bool) {
	token := r.URL.Query().Get("ticket")
	generation := store.generation.Load()
	ticket, ok := store.Validate(token, mediaID)
	if !ok {
		w.Header().Set("Cache-Control", "no-store")
		http.Error(w, "valid playback ticket required; update your client if necessary", http.StatusUnauthorized)
		return w, false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	return &GuardWriter{
		ResponseWriter: w,
		Store:          store,
		Token:          token,
		MediaID:        mediaID,
		validUntil:     ticket.ExpiresAt,
		generation:     generation,
	}, true
}
