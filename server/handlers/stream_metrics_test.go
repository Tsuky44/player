package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The metrics wrapper must not change what a range request returns: it sits on
// the Direct Play hot path whenever the timings are switched on.
func TestStreamMetricsServesRangesUnchanged(t *testing.T) {
	body := strings.Repeat("0123456789", 100_000)
	req := httptest.NewRequest(http.MethodGet, "/stream?media_id=7", nil)
	req.Header.Set("Range", "bytes=10-19")
	rec := httptest.NewRecorder()

	var lines []string
	m := newStreamMetrics(rec, req, 7, time.Now())
	m.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	m.noteOpened()
	http.ServeContent(m, req, "film.mkv", time.Time{}, strings.NewReader(body))

	if rec.Code != http.StatusPartialContent || rec.Body.String() != "0123456789" {
		t.Fatalf("got %d %q, want 206 with the asked range", rec.Code, rec.Body.String())
	}
	if m.bytes != 10 {
		t.Fatalf("counted %d bytes, want 10", m.bytes)
	}
	done := m.describe()
	if !strings.Contains(done, `range="bytes=10-19"`) || !strings.Contains(done, "bytes=10 ") {
		t.Fatalf("summary does not name the range and the bytes sent: %s", done)
	}
}

// The first byte is logged when it leaves, not with the total: the read-ahead
// request stays open for the whole film.
func TestStreamMetricsLogsTheFirstByteOnce(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/stream?media_id=7", nil)
	var lines []string
	m := newStreamMetrics(httptest.NewRecorder(), req, 7, time.Now())
	m.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	_, _ = m.Write([]byte("abc"))
	_, _ = m.Write([]byte("def"))

	if len(lines) != 1 || !strings.Contains(lines[0], "first_byte_ms=") {
		t.Fatalf("want one first-byte line, got %q", lines)
	}
}
