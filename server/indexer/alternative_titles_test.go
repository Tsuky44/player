package indexer

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"project-player/server/httpx"
	"project-player/server/models"
)

// fakeTMDBForAlternativeTitles sert une fiche française que TMDB retrouve par
// son nom anglais, sans que ce nom figure dans son titre ni son titre original.
func fakeTMDBForAlternativeTitles(t *testing.T, altTitlesJSON string) {
	t.Helper()
	t.Setenv("TMDB_API_KEY", "test-key")
	ResetSearchCache()
	t.Cleanup(ResetSearchCache)
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		body := `{}`
		switch {
		case r.URL.Path == "/3/search/tv":
			body = `{"results":[{"id":100,"name":"L'amour est dans le pré","original_name":"L'amour est dans le pré","first_air_date":"2005-06-20","poster_path":"/p.jpg"}]}`
		case r.URL.Path == "/3/tv/100" && strings.Contains(r.URL.RawQuery, "append_to_response"):
			body = altTitlesJSON
		case r.URL.Path == "/3/tv/100":
			body = `{"id":100,"name":"L'amour est dans le pré","original_name":"L'amour est dans le pré","overview":"Des agriculteurs cherchent l'amour.","poster_path":"/p.jpg","first_air_date":"2005-06-20"}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old })
}

func TestIdentify_EnglishFolderMatchesFrenchShowThroughAlternativeTitle(t *testing.T) {
	fakeTMDBForAlternativeTitles(t, `{"alternative_titles":{"results":[{"iso_3166_1":"US","title":"Farmer Wants a Wife"}]}}`)

	match := IdentifyFromRawName("Farmer Wants a Wife", models.TypeShow)
	if !match.Matched || match.TMDBID != 100 {
		t.Fatalf("want TMDB 100 through its alternative title, got %+v", match)
	}
	if match.Title != "L'amour est dans le pré" {
		t.Fatalf("the library must show the French title, got %q", match.Title)
	}
}

func TestIdentify_TranslatedTitleAlsoCountsAsAlternative(t *testing.T) {
	fakeTMDBForAlternativeTitles(t, `{"translations":{"translations":[{"iso_639_1":"en","data":{"name":"Farmer Wants a Wife"}}]}}`)

	if match := IdentifyFromRawName("Farmer Wants a Wife", models.TypeShow); match.TMDBID != 100 {
		t.Fatalf("want TMDB 100 through its English translation, got %+v", match)
	}
}

func TestIdentify_UnrelatedAlternativeTitlesStillRejectWeakMatch(t *testing.T) {
	fakeTMDBForAlternativeTitles(t, `{"alternative_titles":{"results":[{"title":"Love in the Meadow"}]}}`)

	if match := IdentifyFromRawName("Farmer Wants a Wife", models.TypeShow); match.Matched {
		t.Fatalf("alternative titles must not lower the confidence gates, got %+v", match)
	}
}
