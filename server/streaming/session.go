package streaming

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

var (
	errFFmpegDied  = errors.New("ffmpeg process died before producing output")
	errWaitTimeout = errors.New("timeout waiting for transcoder output")
	// segmentsAhead is expressed in segments, so it must track segmentDuration
	// to keep the same ~32s just-in-time buffer.
	segmentsAhead   = 32 / segmentDuration
	throttleEnabled = true
)

// lockedBuffer collects FFmpeg's stderr for later inspection.
//
// os/exec writes to cmd.Stderr from its own goroutine while request goroutines
// read it, which an unguarded bytes.Buffer does not survive. It was a latent
// race while only a failed start read the buffer; /start now inspects it on
// every session — after a 750ms probe, with FFmpeg definitely still running —
// so it is a race that would actually be hit.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// TranscodeSession represents a single active HLS transcoding session.
type TranscodeSession struct {
	ID          string
	MediaID     int
	Quality     string
	AudioIndex  int // default audio track (0:a:N) for this session
	StartOffset int // seconds into the original media where the HLS timeline begins
	TmpDir      string
	Probe       *ProbeResult
	// MasterPlaylist is the master this session publishes, rendered once at
	// /start from the parameters it was created with. See BuildMasterPlaylist.
	MasterPlaylist string
	// SegmentExt is the extension the muxer writes segments with, ".ts" or
	// ".m4s". The throttler counts segment files by name, so it has to know
	// which name the session is producing; empty means ".ts".
	SegmentExt string

	ctx    context.Context
	cancel context.CancelFunc
	cmd    *exec.Cmd
	stderr lockedBuffer

	mu                   sync.Mutex
	active               bool
	paused               bool
	lastAccess           time.Time
	lastRequestedSegment int
	producedSegments     int
}

// Start launches FFmpeg and the JIT throttling watchdog.
func (s *TranscodeSession) Start() error {
	s.mu.Lock()
	if err := s.cmd.Start(); err != nil {
		s.mu.Unlock()
		return err
	}
	s.active = true
	s.lastAccess = time.Now()
	s.mu.Unlock()

	go s.watch()
	if throttleEnabled {
		go s.throttle()
	}
	return nil
}

// watch reaps the process so it never becomes a zombie and records its exit.
func (s *TranscodeSession) watch() {
	_ = s.cmd.Wait()
	s.mu.Lock()
	s.active = false
	s.mu.Unlock()
}

// IsActive reports whether the FFmpeg process is still running.
func (s *TranscodeSession) IsActive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// Touch updates the last-access time (called on each playlist/segment request).
func (s *TranscodeSession) Touch() {
	s.mu.Lock()
	s.lastAccess = time.Now()
	s.mu.Unlock()
}

// LastAccess returns the last-access time (used by the idle reaper).
func (s *TranscodeSession) LastAccess() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastAccess
}

// NoteSegment records the highest video segment index the client has fetched.
// The throttler uses it to keep only a small buffer transcoded ahead, so a
// paused or idle client never causes the whole movie to be processed.
func (s *TranscodeSession) NoteSegment(index int) {
	s.mu.Lock()
	if index > s.lastRequestedSegment {
		s.lastRequestedSegment = index
	}
	s.lastAccess = time.Now()
	s.mu.Unlock()
}

// throttle keeps the transcoder at most segmentsAhead segments in front of the
// client's current position by pausing (SIGSTOP) and resuming (SIGCONT) FFmpeg.
// This gives a true sliding-window / just-in-time buffer: CPU and disk are only
// spent on the part of the film the user is actually watching.
func (s *TranscodeSession) throttle() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			if !s.IsActive() {
				return
			}
			produced := s.countVideoSegments()

			s.mu.Lock()
			bufferAhead := (produced - 1) - s.lastRequestedSegment
			paused := s.paused
			s.mu.Unlock()

			if bufferAhead >= segmentsAhead && !paused {
				s.signal(syscall.SIGSTOP)
				s.mu.Lock()
				s.paused = true
				s.mu.Unlock()
			} else if bufferAhead < segmentsAhead && paused {
				s.signal(syscall.SIGCONT)
				s.mu.Lock()
				s.paused = false
				s.mu.Unlock()
			}
		}
	}
}

// countVideoSegments returns how many .ts segments of the video rendition have
// been produced.
//
// Segments are numbered sequentially and never removed, so this walks forward
// from the last known count instead of re-reading the whole directory. The old
// full ReadDir ran once per second per session over a directory that reaches
// thousands of entries on a feature-length film.
func (s *TranscodeSession) countVideoSegments() int {
	s.mu.Lock()
	n := s.producedSegments
	s.mu.Unlock()

	ext := s.segmentExt()
	for {
		path := filepath.Join(s.TmpDir, fmt.Sprintf("stream_0_%03d%s", n, ext))
		if _, err := os.Stat(path); err != nil {
			break
		}
		n++
	}

	s.mu.Lock()
	if n > s.producedSegments {
		s.producedSegments = n
	}
	n = s.producedSegments
	s.mu.Unlock()
	return n
}

// segmentExt is the extension this session's segments carry, defaulting to
// MPEG-TS for a session created before the field existed.
func (s *TranscodeSession) segmentExt() string {
	if s.SegmentExt == "" {
		return ".ts"
	}
	return s.SegmentExt
}

func (s *TranscodeSession) signal(sig syscall.Signal) {
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Signal(sig)
	}
}

// Kill terminates FFmpeg (continuing it first if paused) and removes temp files.
func (s *TranscodeSession) Kill() {
	s.mu.Lock()
	if !s.active {
		s.mu.Unlock()
		s.cleanup()
		return
	}
	s.mu.Unlock()

	s.cancel()

	if s.cmd.Process != nil {
		// A stopped process ignores SIGTERM, so resume it first.
		_ = s.cmd.Process.Signal(syscall.SIGCONT)
		_ = s.cmd.Process.Signal(syscall.SIGTERM)

		done := make(chan struct{})
		go func() {
			for s.IsActive() {
				time.Sleep(20 * time.Millisecond)
			}
			close(done)
		}()

		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = s.cmd.Process.Kill()
		}
	}

	s.mu.Lock()
	s.active = false
	s.mu.Unlock()

	s.cleanup()
}

func (s *TranscodeSession) cleanup() {
	if s.TmpDir == "" {
		return
	}
	if err := os.RemoveAll(s.TmpDir); err != nil {
		log.Printf("Session %s: failed to remove temp dir %s: %v", s.ID, s.TmpDir, err)
	} else {
		log.Printf("Session %s: cleaned up temp dir %s", s.ID, s.TmpDir)
	}
}

// WaitForFile polls for a file (relative to TmpDir) to appear, failing fast if
// FFmpeg dies first.
func (s *TranscodeSession) WaitForFile(name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	path := s.TmpDir + "/" + name

	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if !s.IsActive() {
			if errStr := s.stderr.String(); errStr != "" {
				log.Printf("Session %s: ffmpeg stderr: %s", s.ID, errStr)
			}
			return errFFmpegDied
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Running out of budget is not a failure for the caller that matters here:
	// /start probes briefly and expects to time out on a healthy session. Anything
	// FFmpeg found worth printing in that window still is worth seeing.
	if errStr := s.stderr.String(); errStr != "" {
		log.Printf("Session %s: ffmpeg stderr while waiting for %s: %s", s.ID, name, errStr)
	}
	return errWaitTimeout
}
