package webui

import (
	"net/http/httptest"
	"testing"
	"testing/fstest"
)

// Une autre page ne doit pas pouvoir afficher l'app dans un cadre.
func TestServeFileRefusesToBeFramed(t *testing.T) {
	h := &Handler{
		files: fstest.MapFS{"index.html": {Data: []byte("<html></html>")}},
		etags: map[string]string{"index.html": `"x"`},
	}
	rec := httptest.NewRecorder()
	if !h.serveFile(rec, httptest.NewRequest("GET", "/", nil), "index.html") {
		t.Fatal("index.html not served")
	}
	if got := rec.Header().Get("X-Frame-Options"); got != "DENY" {
		t.Errorf("X-Frame-Options = %q, want DENY", got)
	}
	if got := rec.Header().Get("Content-Security-Policy"); got == "" {
		t.Error("no Content-Security-Policy")
	}
}
