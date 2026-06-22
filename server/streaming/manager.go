package streaming

import (
	"errors"
	"log"
	"sync"
	"time"
)

var (
	errFFmpegDied             = errors.New("ffmpeg process died before producing output")
	errTimeoutWaitingForPlaylist = errors.New("timeout waiting for variant playlist")
)

// SessionManager manages all active transcoding sessions.
type SessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*TranscodeSession
}

// NewSessionManager creates a new SessionManager and starts the background reaper.
func NewSessionManager() *SessionManager {
	m := &SessionManager{
		sessions: make(map[string]*TranscodeSession),
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
			if time.Since(s.LastAccess()) > 5*time.Minute {
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
