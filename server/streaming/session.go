package streaming

import (
	"bytes"
	"context"
	"log"
	"os"
	"os/exec"
	"sync"
	"time"
)

// TranscodeSession represents a single active HLS transcoding session.
type TranscodeSession struct {
	ID         string
	MediaID    int
	Quality    string
	AudioIndex int
	TmpDir     string
	Probe      *ProbeResult
	ctx        context.Context
	cancel     context.CancelFunc
	cmd        *exec.Cmd
	mu         sync.Mutex
	active     bool
	lastAccess time.Time
	stderr     bytes.Buffer
}

// Start launches the FFmpeg process associated with this session.
func (s *TranscodeSession) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.cmd.Start(); err != nil {
		return err
	}
	s.active = true
	s.lastAccess = time.Now()
	return nil
}

// IsActive returns whether the FFmpeg process is still running.
func (s *TranscodeSession) IsActive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// Touch updates the last access time (called on each segment/playlist request).
func (s *TranscodeSession) Touch() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastAccess = time.Now()
}

// LastAccess returns the last access time (used by the reaper).
func (s *TranscodeSession) LastAccess() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastAccess
}

// Kill terminates the FFmpeg process and cleans up the temp directory.
// It sends SIGTERM, waits up to 3 seconds, then sends SIGKILL if still alive.
func (s *TranscodeSession) Kill() {
	s.mu.Lock()
	if !s.active {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	// Cancel the context (signals any goroutines waiting on it)
	s.cancel()

	// Send SIGTERM
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Signal(os.Interrupt)

		done := make(chan struct{})
		go func() {
			s.cmd.Wait()
			close(done)
		}()

		select {
		case <-done:
		case <-time.After(3 * time.Second):
			// Force kill
			_ = s.cmd.Process.Kill()
			<-done
		}
	}

	s.mu.Lock()
	s.active = false
	s.mu.Unlock()

	// Clean up temp directory
	if s.TmpDir != "" {
		if err := os.RemoveAll(s.TmpDir); err != nil {
			log.Printf("Session %s: failed to remove temp dir %s: %v", s.ID, s.TmpDir, err)
		} else {
			log.Printf("Session %s: cleaned up temp dir %s", s.ID, s.TmpDir)
		}
	}
}

// WaitForVariantPlaylist polls for the variant.m3u8 file to appear in the temp dir.
// Returns nil if the file appears within the timeout, or an error otherwise.
func (s *TranscodeSession) WaitForVariantPlaylist(timeout time.Duration) error {
	return s.WaitForFile("variant.m3u8", timeout)
}

// WaitForFile polls for the given file (relative to the session temp dir) to
// appear. Returns nil if it appears within the timeout, or an error otherwise.
// It also fails fast if the FFmpeg process dies before the file is written.
func (s *TranscodeSession) WaitForFile(name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	playlistPath := s.TmpDir + "/" + name

	for time.Now().Before(deadline) {
		if _, err := os.Stat(playlistPath); err == nil {
			return nil
		}

		// Check if FFmpeg is still alive
		if !s.IsActive() {
			stderrStr := s.stderr.String()
			if len(stderrStr) > 0 {
				log.Printf("Session %s: FFmpeg stderr: %s", s.ID, stderrStr)
			}
			return errFFmpegDied
		}

		time.Sleep(50 * time.Millisecond)
	}

	// Timeout — log stderr for debugging
	stderrStr := s.stderr.String()
	if len(stderrStr) > 0 {
		log.Printf("Session %s: FFmpeg stderr on timeout: %s", s.ID, stderrStr)
	}
	return errTimeoutWaitingForPlaylist
}
