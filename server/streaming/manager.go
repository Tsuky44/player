package streaming

import (
	"log"
	"project-player/server/playbackauth"
	"sync"
	"time"
)

// SessionManager manages all active transcoding sessions.
type SessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*TranscodeSession
	tickets  *playbackauth.Store
}

// NewSessionManager creates a new SessionManager and starts the background reaper.
func NewSessionManager(tickets *playbackauth.Store) *SessionManager {
	m := &SessionManager{
		sessions: make(map[string]*TranscodeSession),
		tickets:  tickets,
	}
	go m.reaper()
	return m
}

// CreateSession creates a new transcoding session, starts FFmpeg, and returns the session.
func (m *SessionManager) CreateSession(session *TranscodeSession) {
	m.mu.Lock()
	m.sessions[session.ID] = session
	m.mu.Unlock()
	log.Printf("SessionManager: created session %s for media %d quality %s", session.ID, session.MediaID, session.Quality)
}

// GetSession retrieves a session by ID.
func (m *SessionManager) GetSession(id string) (*TranscodeSession, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

// Count reports how many transcoding sessions are running.
func (m *SessionManager) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.sessions)
}

// LiveCountExcept compte les sessions que le plafond de maxTranscodes borne :
// ni celles déjà remplacées, ni celles du ticket qui demande une nouvelle
// session — la nouvelle va les remplacer, et un changement de qualité au
// plafond ne doit pas être refusé pour cela.
func (m *SessionManager) LiveCountExcept(ticket [32]byte) int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n := 0
	for _, s := range m.sessions {
		if !s.superseded && s.TicketHash != ticket {
			n++
		}
	}
	return n
}

// supersedeGrace est ce qu'une session remplacée garde à vivre.
//
// Un saut hors de la session, un changement de qualité ou de sous-titre
// incrusté ouvrent une nouvelle session sur le même ticket, et le client ne
// détruit l'ancienne qu'une fois la nouvelle prête — ou jamais, s'il plante
// entre-temps : elle tournait alors jusqu'à l'inactivité, cinq minutes. La
// détruire tout de suite couperait l'image que le client montre encore pendant
// l'ouverture de la nouvelle, d'où ce délai.
var supersedeGrace = 30 * time.Second

// Supersede marque comme remplacées les sessions ouvertes avec ce ticket,
// sauf keepID, et les détruit au bout de supersedeGrace si le client ne l'a
// pas fait avant.
func (m *SessionManager) Supersede(ticket [32]byte, keepID string) {
	m.mu.Lock()
	var ids []string
	for id, s := range m.sessions {
		if id != keepID && s.TicketHash == ticket && !s.superseded {
			s.superseded = true
			ids = append(ids, id)
		}
	}
	m.mu.Unlock()
	for _, id := range ids {
		id := id
		time.AfterFunc(supersedeGrace, func() { m.DestroySession(id) })
	}
}

// DestroyAll arrête toutes les sessions, à l'arrêt du serveur. En parallèle :
// chacune peut attendre trois secondes que son FFmpeg s'arrête, et l'arrêt
// d'un conteneur ne laisse que dix secondes avant de tout tuer.
func (m *SessionManager) DestroyAll() {
	m.mu.RLock()
	ids := make([]string, 0, len(m.sessions))
	for id := range m.sessions {
		ids = append(ids, id)
	}
	m.mu.RUnlock()
	var wg sync.WaitGroup
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			m.DestroySession(id)
		}(id)
	}
	wg.Wait()
}

// DestroySession kills the FFmpeg process, cleans up temp files, and removes the session.
func (m *SessionManager) DestroySession(id string) {
	m.mu.Lock()
	session, ok := m.sessions[id]
	if ok {
		delete(m.sessions, id)
	}
	m.mu.Unlock()

	if ok {
		session.Kill()
		log.Printf("SessionManager: destroyed session %s", id)
	}
}

// reaper runs periodically to kill idle sessions and clean up zombie processes.
func (m *SessionManager) reaper() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		m.mu.RLock()
		var toKill []string
		for id, s := range m.sessions {
			if time.Since(s.LastAccess()) > 5*time.Minute || (m.tickets != nil && !m.tickets.IsLive(s.TicketHash, s.MediaID)) {
				toKill = append(toKill, id)
			}
		}
		m.mu.RUnlock()

		for _, id := range toKill {
			log.Printf("SessionManager: reaper killing idle session %s", id)
			m.DestroySession(id)
		}
	}
}
