// Package webui serves the Flutter Web bundle that ships inside the server
// binary.
//
// The bundle is produced by `flutter build web` and copied into ./dist by
// publish-image.sh before `go build` runs, so a release stays a single
// self-contained executable — no static directory to deploy alongside it, and
// no second container.
package webui

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"path"
	"strings"
)

// dist holds the built bundle. The `all:` prefix is required because Flutter
// emits dotfiles the default embed patterns would skip.
//
// A checked-in .gitkeep keeps this compiling on a clean checkout where nobody
// has run `flutter build web` yet; Available() reports that case so main.go can
// skip wiring the routes.
//
//go:embed all:dist
var dist embed.FS

// cacheControl is "no-cache" for the whole bundle, which asks the browser to
// revalidate before reusing a stored response rather than to stop storing it.
//
// A longer max-age would be wrong here: Flutter puts no content hash in any of
// the names it emits — index.html, main.dart.js and everything under assets/
// keep their name from one build to the next. Anything held without
// revalidation therefore serves the previous deploy under the current name, and
// mixes an old app shell with new assets.
//
// Revalidation is cheap because New() hashes every file at startup: a client
// that is already up to date gets a 304 with no body, and keeps the bytes it
// has. Only what actually changed is downloaded again.
const cacheControl = "no-cache"

// Handler serves the embedded bundle, falling back to index.html so client-side
// routes (/films, /media/42) survive a reload or a shared link.
type Handler struct {
	files fs.FS
	// etags maps a bundle path to the hash of its contents. Embedded files have
	// no modification time, so without this every revalidation would be a full
	// re-download of a 3.7 MB script.
	etags map[string]string
}

// Available reports whether a bundle was actually embedded. False on a checkout
// where the web target has never been built.
func Available() bool {
	_, err := fs.Stat(dist, "dist/index.html")
	return err == nil
}

// New builds the handler and hashes the bundle once, at startup.
func New() (*Handler, error) {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		return nil, err
	}

	h := &Handler{files: sub, etags: map[string]string{}}
	err = fs.WalkDir(sub, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		f, err := sub.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()

		sum := sha256.New()
		if _, err := io.Copy(sum, f); err != nil {
			return err
		}
		h.etags[p] = `"` + hex.EncodeToString(sum.Sum(nil)[:16]) + `"`
		return nil
	})
	if err != nil {
		return nil, err
	}

	log.Printf("WebUI: serving embedded Flutter bundle (%d files)", len(h.etags))
	return h, nil
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// An unmatched /api path is a genuine 404, not a client-side route. Serving
	// the SPA shell there would hand an HTML page to a JSON caller and turn
	// every typo'd endpoint into a confusing parse error.
	if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/stream" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error": "not found"}`))
		return
	}

	name := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if name == "" || name == "." {
		name = "index.html"
	}

	if !h.serveFile(w, r, name) {
		// Unknown path: hand back the app shell and let the Flutter router
		// resolve it.
		h.serveFile(w, r, "index.html")
	}
}

// serveFile writes one bundle file, preferring a pre-compressed sibling when the
// client accepts it. Returns false if the file is not in the bundle.
func (h *Handler) serveFile(w http.ResponseWriter, r *http.Request, name string) bool {
	etag, ok := h.etags[name]
	if !ok {
		return false
	}

	contentType := mime.TypeByExtension(path.Ext(name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	// publish-image.sh pre-compresses the large text assets. Serving those saves
	// ~70% of the transfer without spending CPU per request, and works even when
	// the reverse proxy in front has no gzip configured.
	served := name
	if _, gzOK := h.etags[name+".gz"]; gzOK &&
		strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		served = name + ".gz"
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")
	}

	w.Header().Set("Content-Type", contentType)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", cacheControl)

	// Revalidation hit: the browser already holds this exact content.
	if match := r.Header.Get("If-None-Match"); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return true
	}

	f, err := h.files.Open(served)
	if err != nil {
		return false
	}
	defer f.Close()

	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return true
	}
	if _, err := io.Copy(w, f); err != nil {
		log.Printf("WebUI: failed to write %s: %v", served, err)
	}
	return true
}
