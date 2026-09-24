package handlers

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// streamDebugEnv turns the /stream timings on without touching the command
// line, which a container image does not expose.
var streamDebugEnv, _ = strconv.ParseBool(strings.TrimSpace(os.Getenv("STREAM_DEBUG")))

func streamDebugEnabled() bool { return *streamDebug || streamDebugEnv }

// streamMetrics times one /stream request, for the client's start-up trace.
//
// The client sees its start-up stall between "play" and the first frame and
// cannot tell the server's disk from the network. These are the server's half:
// how long the file took to open, how long until the first byte left, and at
// what rate the rest went. A first byte that takes seconds is a disk waking up
// or a network mount; a quick first byte with a slow rate is the link.
//
// The previous metric logged the file size as "bytes" and only the total
// duration, which for the long read-ahead request is the length of the film.
type streamMetrics struct {
	http.ResponseWriter
	mediaID   int
	rangeHdr  string
	start     time.Time
	opened    time.Duration
	firstByte time.Duration
	bytes     int64
	logf      func(format string, args ...any)
}

func newStreamMetrics(w http.ResponseWriter, r *http.Request, mediaID int, start time.Time) *streamMetrics {
	return &streamMetrics{
		ResponseWriter: w,
		mediaID:        mediaID,
		rangeHdr:       r.Header.Get("Range"),
		start:          start,
		logf:           log.Printf,
	}
}

// noteOpened marks the file as resolved and open, the moment before any read.
func (m *streamMetrics) noteOpened() { m.opened = time.Since(m.start) }

func (m *streamMetrics) Write(p []byte) (int, error) {
	n, err := m.ResponseWriter.Write(p)
	if m.bytes == 0 && n > 0 {
		m.firstByte = time.Since(m.start)
		// Written now rather than with the total: the read-ahead request stays
		// open for the whole film, and its first byte is what start-up waits on.
		m.logf("stream first byte media_id=%d range=%q open_ms=%d first_byte_ms=%d",
			m.mediaID, m.rangeHdr, m.opened.Milliseconds(), m.firstByte.Milliseconds())
	}
	m.bytes += int64(n)
	return n, err
}

// ReadFrom keeps the large copy buffer the ticket guard picks (see
// playbackauth.GuardWriter.ReadFrom) while every byte still passes through
// Write, where it is counted.
func (m *streamMetrics) ReadFrom(src io.Reader) (int64, error) {
	buf := make([]byte, 256<<10)
	return io.CopyBuffer(struct{ io.Writer }{m}, src, buf)
}

func (m *streamMetrics) describe() string {
	elapsed := time.Since(m.start)
	rate := 0.0
	if streaming := elapsed - m.firstByte; m.bytes > 0 && streaming > 0 {
		rate = float64(m.bytes) * 8 / streaming.Seconds() / 1e6
	}
	return fmt.Sprintf("stream done media_id=%d range=%q open_ms=%d first_byte_ms=%d bytes=%d duration_ms=%d rate_mbps=%.1f",
		m.mediaID, m.rangeHdr, m.opened.Milliseconds(), m.firstByte.Milliseconds(),
		m.bytes, elapsed.Milliseconds(), rate)
}
