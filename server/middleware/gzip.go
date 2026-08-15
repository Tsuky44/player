// Package middleware holds the HTTP wrappers applied to the whole router.
package middleware

import (
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"sync"
)

// Gzip compresses JSON API responses.
//
// The library endpoints return the whole catalog in one document — /api/movies
// carries every film with its overview — and none of it was compressed: the web
// bundle ships pre-compressed siblings, but the API had nothing. JSON of that
// shape compresses 5–10×, which is the difference between a snappy and a
// sluggish library screen on a phone.
//
// The scope is deliberately narrow. Only /api/ paths are eligible, and within
// those the media routes are excluded: HLS segments and installers are already
// compressed, so re-compressing them would burn CPU on the transcoding host for
// nothing, and the subtitle route is fetched by libmpv itself, which is left on
// exactly the bytes it gets today.
func Gzip(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !compressible(r.URL.Path) || !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}

		// Vary matters even for a response we end up not compressing: a cache
		// must not hand a gzipped body to a client that cannot read one.
		w.Header().Add("Vary", "Accept-Encoding")

		gw := &gzipResponseWriter{ResponseWriter: w}
		defer gw.Close()
		next.ServeHTTP(gw, r)
	})
}

// gzipMinSize is the payload below which compression is not worth its overhead:
// a few hundred bytes of JSON gain nothing, and the gzip framing can make the
// smallest replies larger than they started.
const gzipMinSize = 1024

func compressible(path string) bool {
	if !strings.HasPrefix(path, "/api/") {
		return false
	}
	switch {
	case strings.HasPrefix(path, "/api/v1/stream/"), // HLS playlists and segments
		strings.HasPrefix(path, "/api/v1/media/"), // WebVTT fetched by libmpv
		strings.HasPrefix(path, "/api/downloads"): // APK/DMG/EXE installers
		return false
	}
	return true
}

var gzipWriters = sync.Pool{
	New: func() any { return gzip.NewWriter(io.Discard) },
}

// gzipResponseWriter buffers the start of the body so the size threshold can be
// applied, then either switches to compressing or replays the buffer untouched.
type gzipResponseWriter struct {
	http.ResponseWriter

	status  int
	buf     []byte
	gz      *gzip.Writer
	decided bool // true once the response is committed one way or the other
}

// WriteHeader holds the status back until the body is seen, because that is
// when we know whether Content-Encoding applies.
func (w *gzipResponseWriter) WriteHeader(status int) {
	if !w.decided {
		w.status = status
		return
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *gzipResponseWriter) Write(b []byte) (int, error) {
	if w.decided {
		if w.gz != nil {
			return w.gz.Write(b)
		}
		return w.ResponseWriter.Write(b)
	}

	// A handler that set Content-Encoding itself has already compressed its
	// body; compressing it again would produce something no client can read.
	if w.ResponseWriter.Header().Get("Content-Encoding") != "" {
		w.commitPlain()
		return w.ResponseWriter.Write(b)
	}

	w.buf = append(w.buf, b...)
	if len(w.buf) >= gzipMinSize {
		w.commitGzip()
	}
	return len(b), nil
}

// commitGzip switches the response to gzip and flushes what was buffered.
func (w *gzipResponseWriter) commitGzip() {
	w.decided = true

	header := w.ResponseWriter.Header()
	// Content-Length describes the uncompressed body and would be wrong; the
	// client gets a chunked response instead.
	header.Del("Content-Length")
	header.Set("Content-Encoding", "gzip")

	w.gz = gzipWriters.Get().(*gzip.Writer)
	w.gz.Reset(w.ResponseWriter)

	w.sendStatus()
	if len(w.buf) > 0 {
		_, _ = w.gz.Write(w.buf)
		w.buf = nil
	}
}

// commitPlain gives up on compressing and replays the buffer as-is.
func (w *gzipResponseWriter) commitPlain() {
	w.decided = true
	w.sendStatus()
	if len(w.buf) > 0 {
		_, _ = w.ResponseWriter.Write(w.buf)
		w.buf = nil
	}
}

func (w *gzipResponseWriter) sendStatus() {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	w.ResponseWriter.WriteHeader(w.status)
}

// Close finishes the response. A body that never reached the threshold is sent
// uncompressed here; anything already committed to gzip is flushed and closed.
func (w *gzipResponseWriter) Close() {
	if w.gz != nil {
		_ = w.gz.Close()
		gzipWriters.Put(w.gz)
		w.gz = nil
		return
	}
	if !w.decided {
		w.commitPlain()
	}
}

// Flush keeps streaming handlers working. Flushing means the handler has
// committed to a body, so the decision can no longer be deferred.
func (w *gzipResponseWriter) Flush() {
	if !w.decided {
		w.commitGzip()
	}
	if w.gz != nil {
		_ = w.gz.Flush()
	}
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
