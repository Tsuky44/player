package handlers

import (
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"project-player/server/ttlcache"
)

// fakeTMDB compte les appels et rend status avec body.
type fakeTMDB struct {
	calls  atomic.Int32
	status int
	body   string
}

func (f *fakeTMDB) RoundTrip(r *http.Request) (*http.Response, error) {
	f.calls.Add(1)
	return &http.Response{StatusCode: f.status, Body: io.NopCloser(strings.NewReader(f.body)), Header: make(http.Header), Request: r}, nil
}

func TestCatalogPageIsAskedOnceToTMDBWhileCached(t *testing.T) {
	t.Setenv("TMDB_API_KEY", "test-key")
	tmdbCatalogPages = newCatalogPageCacheForTest(t)
	fake := &fakeTMDB{status: http.StatusOK, body: `{"page":2,"total_pages":9,"results":[{"id":603,"media_type":"movie","title":"Matrix"}]}`}
	client := &http.Client{Transport: fake}

	// La page préchargée par l'app, puis la même demandée pour de bon : un seul appel TMDB.
	for range 2 {
		page, err := cachedTMDBCatalogPage(client, "/trending/all/week?language=fr-FR&page=2")
		if err != nil {
			t.Fatalf("page du catalogue : %v", err)
		}
		if page.Page != 2 || page.TotalPages != 9 || len(page.Results) != 1 || page.Results[0].ID != 603 {
			t.Fatalf("page inattendue : %+v", page)
		}
	}
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("TMDB appelé %d fois, attendu 1", got)
	}
}

func TestFailedCatalogPageIsNotCached(t *testing.T) {
	t.Setenv("TMDB_API_KEY", "test-key")
	tmdbCatalogPages = newCatalogPageCacheForTest(t)
	fake := &fakeTMDB{status: http.StatusServiceUnavailable, body: `{}`}
	client := &http.Client{Transport: fake}

	for range 2 {
		if _, err := cachedTMDBCatalogPage(client, "/search/multi?language=fr-FR&page=1&query=dune"); err == nil {
			t.Fatal("une réponse 503 de TMDB doit remonter en erreur")
		}
	}
	if got := fake.calls.Load(); got != 2 {
		t.Fatalf("TMDB appelé %d fois, attendu 2 : un échec ne doit pas rester en cache", got)
	}
}

// newCatalogPageCacheForTest donne au test un cache vide et rend l'ancien ensuite.
func newCatalogPageCacheForTest(t *testing.T) *ttlcache.Cache[tmdbCatalogResponse] {
	t.Helper()
	previous := tmdbCatalogPages
	t.Cleanup(func() { tmdbCatalogPages = previous })
	return ttlcache.New[tmdbCatalogResponse](tmdbCatalogPageTTL, tmdbCatalogPageMaxEntries)
}
