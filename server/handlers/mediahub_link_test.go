package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"project-player/server/mediahub"
)

// hubStub simule OnyxHub (ou MediaHub) derrière l'adresse réglée dans Onyx.
//
// Il n'a pas l'API v1 de MediaHub : son 404 sur le ping v1 fait parler Onyx
// dans le dialecte d'OnyxHub (ADR-0089).
func hubStub(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	return companionStub(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, mediahub.V1Path) {
			http.NotFound(w, r)
			return
		}
		handler(w, r)
	})
}

// companionStub monte le faux compagnon tel quel, et oublie le dialecte et le
// délai de grâce du lot retenus par le test précédent.
func companionStub(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	t.Setenv("MEDIAHUB_URL", server.URL)
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	mediahub.Reset()
	t.Cleanup(mediahub.Reset)
	return server
}

func TestCatalogAvailabilityAsksOnyxHubForTheWholePageAtOnce(t *testing.T) {
	var calls atomic.Int32
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/api/media/availability" || r.Header.Get("Authorization") != "Bearer cle" {
			t.Errorf("appel inattendu : %s %s", r.Method, r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"tmdbId":603`) || !strings.Contains(string(body), `"mediaType":"tv"`) {
			t.Errorf("lot incomplet : %s", body)
		}
		_, _ = w.Write([]byte(`{"results":[{"tmdbId":603,"mediaType":"movie","status":"available"},{"tmdbId":603,"mediaType":"tv","status":"partial"}]}`))
	})

	items := []catalogItem{{ID: 603, MediaType: "movie"}, {ID: 603, MediaType: "tv"}, {ID: 7, MediaType: "movie"}}
	enrichFromMediaHub(items)

	if calls.Load() != 1 {
		t.Fatalf("appels = %d, attendu un seul pour toute la page", calls.Load())
	}
	// Un film et une série de même identifiant TMDB gardent chacun leur statut.
	if items[0].Status != "available" || items[1].Status != "partial" || items[2].Status != "" {
		t.Fatalf("statuts = %q %q %q", items[0].Status, items[1].Status, items[2].Status)
	}
}

func TestCatalogAvailabilityFallsBackPerCardWhenTheHubHasNoBatchRoute(t *testing.T) {
	var batchCalls, singleCalls atomic.Int32
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			batchCalls.Add(1)
			http.NotFound(w, r)
			return
		}
		singleCalls.Add(1)
		_, _ = w.Write([]byte(`{"status":"pending","seasons":[]}`))
	})

	items := []catalogItem{{ID: 1, MediaType: "movie"}, {ID: 2, MediaType: "movie"}}
	enrichFromMediaHub(items)
	if items[0].Status != "pending" || items[1].Status != "pending" || singleCalls.Load() != 2 {
		t.Fatalf("repli par carte : statuts %q %q, %d appels", items[0].Status, items[1].Status, singleCalls.Load())
	}

	// Le serveur d'en face n'a pas la route : la page suivante ne la redemande pas.
	enrichCatalogAvailability([]catalogItem{{ID: 3, MediaType: "movie"}})
	if batchCalls.Load() != 1 {
		t.Fatalf("lot retenté %d fois, attendu 1 pendant le délai de grâce", batchCalls.Load())
	}
}

func TestLinkTestRecognisesOnyxHubAndItsKey(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/integration/ping" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer cle" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok","service":"onyxhub","version":"0.2.0","features":["availability-batch"]}`))
	})

	result := runLinkTest(t, `{}`)
	if !result.OK || result.Service != "onyxhub" || result.Version != "0.2.0" {
		t.Fatalf("résultat = %+v", result)
	}

	// La clé du formulaire, pas encore enregistrée, est celle qu'on teste.
	refused := runLinkTest(t, `{"mediahub_api_key":"autre"}`)
	if refused.OK || !strings.Contains(refused.Message, "refuse") {
		t.Fatalf("clé refusée = %+v", refused)
	}
}

func TestLinkTestAcceptsAnOldMediaHubWithoutPing(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/media/availability/") {
			_, _ = w.Write([]byte(`{"status":"unknown","seasons":[]}`))
			return
		}
		http.NotFound(w, r)
	})

	if result := runLinkTest(t, ``); !result.OK || result.Service != "mediahub" {
		t.Fatalf("MediaHub = %+v", result)
	}
}

func TestLinkTestSaysWhenTheAddressIsUnreachable(t *testing.T) {
	t.Setenv("MEDIAHUB_URL", "http://127.0.0.1:1")
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	if result := runLinkTest(t, `{}`); result.OK || !strings.Contains(result.Message, "ne joint pas") {
		t.Fatalf("adresse injoignable = %+v", result)
	}
}

func runLinkTest(t *testing.T, body string) mediaHubLinkResult {
	t.Helper()
	recorder := httptest.NewRecorder()
	TestMediaHubLink(recorder, httptest.NewRequest(http.MethodPost, "/api/settings/mediahub/test", strings.NewReader(body)), nil, 1)
	if recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	var result mediaHubLinkResult
	if err := json.NewDecoder(recorder.Body).Decode(&result); err != nil {
		t.Fatalf("décodage : %v", err)
	}
	return result
}
