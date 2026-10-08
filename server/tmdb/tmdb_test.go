package tmdb

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

const testKey = "s3cr3t-tmdb-key"

func TestGetAddsTheKeyAndKeepsTheCallersQuery(t *testing.T) {
	t.Setenv("TMDB_API_KEY", testKey)

	var seen *http.Request
	client := &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		seen = r
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("{}"))}, nil
	})}

	for _, c := range []struct{ in, path, language string }{
		{"/tv/1399?language=fr-FR", "/3/tv/1399", "fr-FR"},
		{"/collection/10", "/3/collection/10", ""},
	} {
		resp, err := Get(client, c.in)
		if err != nil {
			t.Fatalf("Get(%q): %v", c.in, err)
		}
		resp.Body.Close()
		if seen.URL.Host != "api.themoviedb.org" || seen.URL.Path != c.path {
			t.Errorf("Get(%q) asked %s%s", c.in, seen.URL.Host, seen.URL.Path)
		}
		if got := seen.URL.Query().Get("api_key"); got != testKey {
			t.Errorf("Get(%q) sent api_key=%q", c.in, got)
		}
		if got := seen.URL.Query().Get("language"); got != c.language {
			t.Errorf("Get(%q) sent language=%q, want %q", c.in, got, c.language)
		}
	}
}

// Une erreur réseau de net/http cite l'URL entière, clé comprise, et elle
// partait telle quelle dans le journal du serveur.
func TestANetworkErrorNeverCarriesTheKey(t *testing.T) {
	t.Setenv("TMDB_API_KEY", testKey)

	client := &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		return nil, context.DeadlineExceeded
	})}
	_, err := Get(client, "/movie/238?language=en-US")
	if err == nil {
		t.Fatal("expected the transport error")
	}
	if strings.Contains(err.Error(), testKey) || strings.Contains(err.Error(), "api_key") {
		t.Fatalf("the error leaks the key: %v", err)
	}
	if !strings.Contains(err.Error(), "/movie/238") {
		t.Errorf("the error should still say what was asked: %v", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("the cause must stay reachable through errors.Is: %v", err)
	}
}

func TestGetWithoutAKeyAsksNothing(t *testing.T) {
	t.Setenv("TMDB_API_KEY", "")

	client := &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		t.Fatal("a request left without a key")
		return nil, nil
	})}
	if _, err := Get(client, "/movie/238"); !errors.Is(err, ErrNoKey) {
		t.Fatalf("err = %v, want ErrNoKey", err)
	}
}

// Garde : hors de ce package, personne n'écrit l'adresse de l'API TMDB ni son
// paramètre de clé. Une URL construite ailleurs remet la clé dans les erreurs
// réseau, donc dans le journal. Passer par tmdb.Get.
// (image.tmdb.org, qui sert les affiches sans clé, n'est pas concerné.)
func TestOnlyThisPackageBuildsTMDBURLs(t *testing.T) {
	root := ".."
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "tmdb" || d.Name() == "data" || d.Name() == "downloads" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, forbidden := range []string{"api.themoviedb.org", "api_key="} {
			if strings.Contains(string(source), forbidden) {
				t.Errorf("%s contient %q : la clé TMDB finirait dans les erreurs réseau, "+
					"donc dans le journal. Appeler tmdb.Get avec le chemin seul.", path, forbidden)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
