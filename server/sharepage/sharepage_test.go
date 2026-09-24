package sharepage

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/julienschmidt/httprouter"
)

func TestPageIsServedWithItsProtections(t *testing.T) {
	rec := httptest.NewRecorder()
	Page(rec, httptest.NewRequest(http.MethodGet, "/share", nil), nil)
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("page: %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
	for header, want := range map[string]string{
		"Referrer-Policy":         "no-referrer",
		"X-Robots-Tag":            "noindex, nofollow",
		"Content-Security-Policy": "frame-ancestors 'none'",
	} {
		if got := rec.Header().Get(header); !strings.Contains(got, want) {
			t.Errorf("%s = %q, want it to contain %q", header, got, want)
		}
	}
}

// La page ne charge que ses propres fichiers : chaque /share/assets/… qu'elle
// cite doit exister, sinon elle s'affiche vide sans erreur visible.
func TestPageReferencesOnlyExistingAssets(t *testing.T) {
	rec := httptest.NewRecorder()
	Page(rec, httptest.NewRequest(http.MethodGet, "/share", nil), nil)
	refs := regexp.MustCompile(`/share/assets/([\w.-]+)`).FindAllStringSubmatch(rec.Body.String(), -1)
	if len(refs) == 0 {
		t.Fatal("the page references no asset")
	}
	for _, ref := range refs {
		rec := httptest.NewRecorder()
		Asset(rec, httptest.NewRequest(http.MethodGet, ref[0], nil), httprouter.Params{{Key: "file", Value: ref[1]}})
		if rec.Code != http.StatusOK {
			t.Errorf("%s: %d", ref[0], rec.Code)
		}
	}
}

func TestAssetRefusesTraversal(t *testing.T) {
	for _, name := range []string{"../sharepage.go", "..", "missing.js"} {
		rec := httptest.NewRecorder()
		Asset(rec, httptest.NewRequest(http.MethodGet, "/share/assets/x", nil), httprouter.Params{{Key: "file", Value: name}})
		if rec.Code != http.StatusNotFound {
			t.Errorf("%q: %d, want 404", name, rec.Code)
		}
	}
}
