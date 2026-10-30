package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/database"
)

func getReleases(t *testing.T, query string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	MediaHubReleases(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/releases?"+query, nil), nil, 3)
	return recorder
}

func TestReleasesOfAnEpisodeAreReadAtMediaHubInTheNameOfTheAccount(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /releases": func(w http.ResponseWriter, r *http.Request) {
			query := r.URL.Query()
			if query.Get("tmdbId") != "1399" || query.Get("type") != "tv" || query.Get("season") != "2" || query.Get("episode") != "3" {
				t.Errorf("recherche relayée : %s", r.URL.RawQuery)
			}
			if r.Header.Get("X-Player-Username") != "lea" || r.Header.Get("X-Player-Id") != "3" {
				t.Errorf("compte transmis : %q / %q", r.Header.Get("X-Player-Username"), r.Header.Get("X-Player-Id"))
			}
			_, _ = w.Write(mediaHubContract(t, "releases.json"))
		},
	})

	recorder := getReleases(t, "tmdbId=1399&type=tv&season=2&episode=3")

	var got releasesResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &got); err != nil || recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if got.Manager != "sorraa" || len(got.Releases) != 2 {
		t.Fatalf("manager %q, releases = %+v", got.Manager, got.Releases)
	}
	// Avec sorraa : un jeton à la place de l'adresse, et le verdict de son moteur.
	release := got.Releases[0]
	if release.ID != "7f3a9c1e5b" || release.Title != "Show.S02E03.MULTi.1080p.WEB.H264-GRP" || release.IndexerID != 4 ||
		release.Size != 2254857830 || release.Seeders == nil || *release.Seeders != 42 ||
		release.DownloadURL != nil || release.MagnetURL != nil || release.FormatScore != 5 ||
		release.Accepted == nil || !*release.Accepted || len(release.Rejections) != 0 {
		t.Fatalf("release lue = %+v", release)
	}
	refused := got.Releases[1]
	if refused.Accepted == nil || *refused.Accepted || len(refused.Rejections) != 1 {
		t.Fatalf("release refusée lue = %+v", refused)
	}
}

func TestReleasesFromRadarrAndSonarrCarryTheirAddressAndNoVerdict(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /releases": func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write(mediaHubContract(t, "releases_arr.json"))
		},
	})

	var got releasesResponse
	if err := json.Unmarshal(getReleases(t, "tmdbId=1399&type=tv&season=2&episode=3").Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}

	if got.Manager != "arr" || len(got.Releases) != 1 {
		t.Fatalf("manager %q, releases = %+v", got.Manager, got.Releases)
	}
	release := got.Releases[0]
	if release.ID != release.GUID || release.DownloadURL == nil || release.Accepted != nil || release.Rejections == nil {
		t.Fatalf("release lue = %+v", release)
	}
}

func TestReleasesOfAWholeSeasonSendNoEpisode(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /releases": func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Query().Has("episode") || r.URL.Query().Get("season") != "0" {
				t.Errorf("recherche relayée : %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"releases":[]}`))
		},
	})

	recorder := getReleases(t, "tmdbId=1399&type=tv&season=0")

	// Une saison sans résultat est une liste vide, jamais `null` que l'app lirait mal.
	if recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), `"releases":[]`) {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestReleasesRefuseATargetThatMakesNoSense(t *testing.T) {
	for _, query := range []string{
		"type=tv&tmdbId=0",
		"tmdbId=1399&type=music",
		"tmdbId=1399&type=tv&episode=3",
		"tmdbId=603&type=movie&season=1",
		"tmdbId=1399&type=tv&season=-1",
		"tmdbId=1399&type=tv&season=deux",
	} {
		if recorder := getReleases(t, query); recorder.Code != http.StatusBadRequest {
			t.Errorf("%s : HTTP %d, attendu 400", query, recorder.Code)
		}
	}
}

func TestReleasesAreUnsupportedAtAnOlderMediaHubAndAtOnyxHub(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	// Un MediaHub d'avant la route : Next.js répond 404 par une page HTML.
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /releases": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("<html>404</html>"))
		},
	})
	if recorder := getReleases(t, "tmdbId=1399&type=tv&season=1"); recorder.Code != http.StatusNotImplemented {
		t.Fatalf("MediaHub ancien : HTTP %d, attendu 501", recorder.Code)
	}

	hubStub(t, func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	if recorder := getReleases(t, "tmdbId=1399&type=tv&season=1"); recorder.Code != http.StatusNotImplemented {
		t.Fatalf("OnyxHub : HTTP %d, attendu 501", recorder.Code)
	}
}

func TestReleasesRelayMediaHubsRefusal(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /releases": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"Vous n’avez pas le droit de faire cela.","code":"forbidden"}`))
		},
	})
	recorder := getReleases(t, "tmdbId=1399&type=tv&season=1")
	if recorder.Code != http.StatusForbidden || !strings.Contains(recorder.Body.String(), "forbidden") {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestGrabSendsTheChosenReleaseToMediaHubAsTheContractSaysItDoes(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /releases": func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			sameContractJSON(t, "mediahub", mediaHubContract(t, "release_grab.json"), "release_grab.json", body)
			if r.Header.Get("X-Player-Username") != "lea" || r.Header.Get("X-Player-Id") != "3" {
				t.Errorf("compte transmis : %q / %q", r.Header.Get("X-Player-Username"), r.Header.Get("X-Player-Id"))
			}
			_, _ = w.Write([]byte(`{"success":true}`))
		},
	})
	mediaHubStatusCache.Put("1399", map[int]string{2: "processing"})

	recorder := httptest.NewRecorder()
	MediaHubGrabRelease(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/releases/grab",
		strings.NewReader(string(mediaHubContract(t, "release_grab.json")))), nil, 3)

	if recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if _, ok := mediaHubStatusCache.Get("1399"); ok {
		t.Fatal("le statut en cache aurait masqué le téléchargement qui vient de partir")
	}
}

func TestGrabOfARadarrOrSonarrReleaseSendsItsAddressAsTheContractSaysItDoes(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /releases": func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			sameContractJSON(t, "mediahub", mediaHubContract(t, "release_grab_arr.json"), "release_grab_arr.json", body)
			_, _ = w.Write([]byte(`{"success":true}`))
		},
	})

	recorder := httptest.NewRecorder()
	MediaHubGrabRelease(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/releases/grab",
		strings.NewReader(string(mediaHubContract(t, "release_grab_arr.json")))), nil, 3)

	if recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestGrabOfAnExpiredSorraaTokenTellsToSearchAgain(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /releases": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusGone)
			_, _ = w.Write([]byte(`{"error":"La release a expiré : relancez la recherche.","code":"error"}`))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubGrabRelease(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/releases/grab",
		strings.NewReader(string(mediaHubContract(t, "release_grab.json")))), nil, 3)
	if recorder.Code != http.StatusGone || !strings.Contains(recorder.Body.String(), "relancez") {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestGrabRefusesAChoiceThatCannotBeDownloaded(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, nil)
	for name, body := range map[string]string{
		"sans identifiant":    `{"tmdbId":1399,"mediaType":"tv","season":1,"release":{"indexerId":1,"title":"t"}}`,
		"sans titre":          `{"tmdbId":1399,"mediaType":"tv","season":1,"release":{"guid":"g","indexerId":1,"downloadUrl":"https://x/y"}}`,
		"épisode sans saison": `{"tmdbId":1399,"mediaType":"tv","episode":1,"release":{"guid":"g","indexerId":1,"title":"t","downloadUrl":"https://x/y"}}`,
		"corps illisible":     `{"tmdbId":`,
	} {
		recorder := httptest.NewRecorder()
		MediaHubGrabRelease(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/releases/grab", strings.NewReader(body)), nil, 3)
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("%s : HTTP %d, attendu 400", name, recorder.Code)
		}
	}
}

func TestAccessOffersInteractiveSearchOnlyToWhoMayManageSettings(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /ping": func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"status":"ok","service":"mediahub","version":"1.0.0","apiVersion":1,"features":["interactive-search"],` +
				`"webhookConfigured":true,"user":{"linked":true,"id":12,"name":"lea","role":"admin","can":{"request":true,"interactiveSearch":true}}}`))
		},
	})
	canSearch := func() bool {
		recorder := httptest.NewRecorder()
		MediaHubRequestAccess(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/access", nil), nil, 3)
		var access struct {
			Can struct {
				InteractiveSearch bool `json:"interactiveSearch"`
			} `json:"can"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &access); err != nil || recorder.Code != http.StatusOK {
			t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
		}
		return access.Can.InteractiveSearch
	}

	// Un compte homonyme d'un administrateur de MediaHub ne suffit pas : la
	// route d'Onyx le refuserait, l'app ne doit pas le lui proposer.
	if canSearch() {
		t.Fatal("la recherche interactive est proposée à un compte sans manage_settings")
	}
	if _, err := database.DB.Exec(`UPDATE users SET perm_manage_settings = 1 WHERE id = 3`); err != nil {
		t.Fatal(err)
	}
	if !canSearch() {
		t.Fatal("la recherche interactive manque à qui a manage_settings et le droit chez MediaHub")
	}
}

func TestGrabRelaysRadarrOrSonarrRefusalFromMediaHub(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /releases": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":"Radarr ou Sonarr a refusé la release : Rejected","code":"error"}`))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubGrabRelease(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/releases/grab",
		strings.NewReader(string(mediaHubContract(t, "release_grab.json")))), nil, 3)
	if recorder.Code != http.StatusBadGateway || !strings.Contains(recorder.Body.String(), "refusé") {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}
