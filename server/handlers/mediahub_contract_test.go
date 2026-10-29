package handlers

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/mediahub"
)

// Le contrat avec MediaHub, vu d'Onyx (ADR-0089).
//
// contract/mediahub/ est une copie des exemples de MediaHub
// (docs/player-integration/v1/examples/ dans son dépôt) : ce que MediaHub
// écrit doit se lire ici sans rien perdre, et ce qu'Onyx envoie doit valoir
// le fichier. Changer un format, c'est changer le fichier des deux côtés.

const mediaHubContractDir = "../../contract/mediahub"

func mediaHubContract(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(mediaHubContractDir, name))
	if err != nil {
		t.Fatalf("contract/mediahub/%s : %v", name, err)
	}
	return data
}

// v1Stub monte un faux MediaHub v1 : routes sous V1Path, ping compris.
func v1Stub(t *testing.T, routes map[string]http.HandlerFunc) {
	t.Helper()
	companionStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer cle" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		key := r.Method + " " + strings.TrimPrefix(r.URL.Path, mediahub.V1Path)
		if handler, ok := routes[key]; ok {
			handler(w, r)
			return
		}
		if key == "GET /ping" {
			_, _ = w.Write(mediaHubContract(t, "ping.json"))
			return
		}
		t.Errorf("appel inattendu à MediaHub : %s", key)
		http.NotFound(w, r)
	})
}

func seedRequestUser(t *testing.T, id int, name string) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "mediahub.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	if _, err := database.DB.Exec(`INSERT INTO users (id, username, password_hash) VALUES (?, ?, 'x')`, id, name); err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

func TestMediaHubContractLinkTestReadsTheV1PingInTheNameOfTheAdmin(t *testing.T) {
	seedRequestUser(t, 1, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /ping": func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-Player-Username") != "lea" {
				t.Errorf("ping sans le compte de l'administrateur : %q", r.Header.Get("X-Player-Username"))
			}
			_, _ = w.Write(mediaHubContract(t, "ping.json"))
		},
	})
	result := runLinkTest(t, `{}`)
	if !result.OK || result.Service != "mediahub" || result.Version != "0.9.691" || len(result.Notes) != 0 {
		t.Fatalf("résultat = %+v", result)
	}
}

func TestLinkTestSaysWhatMediaHubStillMisses(t *testing.T) {
	seedRequestUser(t, 1, "admin")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /ping": func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"status":"ok","service":"mediahub","version":"1.0.0","apiVersion":1,"features":[],"webhookConfigured":false,"user":{"linked":false,"id":0,"name":"admin","role":"user","can":{}}}`))
		},
	})
	result := runLinkTest(t, `{}`)
	if !result.OK || len(result.Notes) != 2 ||
		!strings.Contains(result.Notes[0], "« admin »") || !strings.Contains(result.Notes[1], "ONYX_WEBHOOK_URL") {
		t.Fatalf("réserves = %+v", result)
	}
}

func TestLinkTestSaysMediaHubRefusesTheKey(t *testing.T) {
	v1Stub(t, nil)
	refused := runLinkTest(t, `{"mediahub_api_key":"autre"}`)
	if refused.OK || refused.Service != "mediahub" || !strings.Contains(refused.Message, "refuse") {
		t.Fatalf("clé refusée = %+v", refused)
	}
}

func TestMediaHubContractAvailabilityKeepsSeasonsAndTheReasonToWait(t *testing.T) {
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /availability/1399": func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Query().Get("type") != "tv" {
				t.Errorf("type = %q", r.URL.Query().Get("type"))
			}
			_, _ = w.Write(mediaHubContract(t, "availability.json"))
		},
	})
	got := fetchMediaHubAvailability(1399, "tv", httpx.Fast)
	if got == nil || got.Status != "partial" || len(got.Seasons) != 2 || got.Seasons[1].Status != "processing" || got.Seasons[0].TotalEpisodes != 10 {
		t.Fatalf("disponibilité lue = %+v", got)
	}
}

func TestMediaHubContractCatalogPageGoesOutInOneBatch(t *testing.T) {
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /availability": func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			sameContractJSON(t, "mediahub", mediaHubContract(t, "availability_batch_request.json"), "availability_batch_request.json", body)
			_, _ = w.Write(mediaHubContract(t, "availability_batch.json"))
		},
	})
	items := []catalogItem{{ID: 603, MediaType: "movie"}, {ID: 1399, MediaType: "tv"}}
	enrichFromMediaHub(items)
	if items[0].Status != "available" || items[1].Status != "partial" {
		t.Fatalf("statuts lus = %q %q", items[0].Status, items[1].Status)
	}
}

func TestMediaHubContractRequestIsRelayedAsSentWithTheAccount(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"POST /requests": func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			sameContractJSON(t, "mediahub", mediaHubContract(t, "request_create.json"), "request_create.json", body)
			// L'id survit à tout ; MediaHub y lie le compte (ADR-0090).
			if r.Header.Get("X-Player-Username") != "lea" || r.Header.Get("X-Player-Id") != "3" {
				t.Errorf("compte transmis : %q / %q", r.Header.Get("X-Player-Username"), r.Header.Get("X-Player-Id"))
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write(mediaHubContract(t, "request_create_response.json"))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubRequest(recorder, httptest.NewRequest(http.MethodPost, "/api/requests", bytes.NewReader(mediaHubContract(t, "request_create.json"))), nil, 3)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestMyRequestsFromMediaHubComeAsLotsWithTheReasonToWait(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /requests": func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Query().Get("scope") != "mine" || r.Header.Get("X-Player-Username") != "lea" {
				t.Errorf("liste demandée : %s pour %q", r.URL.RawQuery, r.Header.Get("X-Player-Username"))
			}
			_, _ = w.Write(mediaHubContract(t, "requests_list.json"))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubMyRequests(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/mine", nil), nil, 3)
	var got myRequestsResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &got); err != nil || recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if len(got.Requests) != 1 {
		t.Fatalf("lots = %+v", got.Requests)
	}
	lot := got.Requests[0]
	if lot.TMDBID != 603 || lot.Status != "approved" || lot.Waiting == nil ||
		lot.Waiting.ReleaseDate != "2026-12-01T00:00:00Z" || len(lot.RequestIDs) != 1 || lot.RequestIDs[0] != 40 {
		t.Fatalf("lot = %+v", lot)
	}
}

func TestMyRequestsFollowMediaHubPages(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	pages := 0
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /requests": func(w http.ResponseWriter, r *http.Request) {
			pages++
			if r.URL.Query().Get("before") == "" {
				_, _ = w.Write([]byte(`{"requests":[{"id":9,"mediaType":"tv","tmdbId":1399,"seasons":[2],"status":"pending"}],"nextBefore":9}`))
				return
			}
			_, _ = w.Write([]byte(`{"requests":[{"id":8,"mediaType":"tv","tmdbId":1399,"seasons":[1],"status":"available"}],"nextBefore":null}`))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubMyRequests(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/mine", nil), nil, 3)
	var got myRequestsResponse
	_ = json.Unmarshal(recorder.Body.Bytes(), &got)
	if pages != 2 || len(got.Requests) != 1 || got.Requests[0].Status != "partial" || len(got.Requests[0].SeasonStatuses) != 2 {
		t.Fatalf("%d pages, lots = %+v", pages, got.Requests)
	}
}

func TestMediaHubContractFeedLeavesOutTheReadersOwnRequests(t *testing.T) {
	seedRequestUser(t, 1, "admin")
	v1Stub(t, map[string]http.HandlerFunc{
		"GET /requests/feed": func(w http.ResponseWriter, r *http.Request) {
			if r.URL.RawQuery != "after=41" {
				t.Errorf("curseur relayé : %q", r.URL.RawQuery)
			}
			_, _ = w.Write(mediaHubContract(t, "request_feed.json"))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubRequestFeed(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/feed?after=41", nil), nil, 1)
	var feed mediahub.Feed
	if err := json.Unmarshal(recorder.Body.Bytes(), &feed); err != nil || recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if feed.Cursor != 42 || len(feed.Requests) != 1 || feed.Requests[0].Requester != "lea" || feed.Requests[0].ID != 41 {
		t.Fatalf("flux = %+v", feed)
	}

	// La même demande, lue par « lea », ne la notifie pas d'elle-même.
	seedRequestUser(t, 2, "Lea")
	recorder = httptest.NewRecorder()
	MediaHubRequestFeed(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/feed?after=41", nil), nil, 2)
	_ = json.Unmarshal(recorder.Body.Bytes(), &feed)
	if len(feed.Requests) != 0 {
		t.Fatalf("flux de lea = %+v", feed.Requests)
	}
}

func TestMediaHubContractModerationSendsTheDecisionForEachLine(t *testing.T) {
	seedRequestUser(t, 1, "admin")
	var patched []string
	decline := func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		sameContractJSON(t, "mediahub", mediaHubContract(t, "request_moderate.json"), "request_moderate.json", body)
		patched = append(patched, r.URL.Path)
		_, _ = w.Write(mediaHubContract(t, "request_detail.json"))
	}
	v1Stub(t, map[string]http.HandlerFunc{"PATCH /requests/41": decline, "PATCH /requests/42": decline})

	recorder := httptest.NewRecorder()
	body := `{"requestIds":[41,42],"action":"decline","reason":"Doublon avec une demande existante"}`
	MediaHubModerateRequests(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/moderation", strings.NewReader(body)), nil, 1)
	if recorder.Code != http.StatusOK || len(patched) != 2 {
		t.Fatalf("HTTP %d, %d lignes : %s", recorder.Code, len(patched), recorder.Body.String())
	}
}

func TestModerationRelaysMediaHubsRefusal(t *testing.T) {
	seedRequestUser(t, 1, "admin")
	v1Stub(t, map[string]http.HandlerFunc{
		"DELETE /requests/41": func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"Forbidden","code":"forbidden"}`))
		},
	})
	recorder := httptest.NewRecorder()
	MediaHubModerateRequests(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/moderation", strings.NewReader(`{"requestIds":[41],"action":"delete"}`)), nil, 1)
	if recorder.Code != http.StatusForbidden || !strings.Contains(recorder.Body.String(), "forbidden") {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestModerationRefusesAnUnknownAction(t *testing.T) {
	for _, body := range []string{`{"requestIds":[1],"action":"ban"}`, `{"requestIds":[],"action":"approve"}`, `{"requestIds":[0],"action":"approve"}`} {
		recorder := httptest.NewRecorder()
		MediaHubModerateRequests(recorder, httptest.NewRequest(http.MethodPost, "/api/requests/moderation", strings.NewReader(body)), nil, 1)
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("%s : HTTP %d, attendu 400", body, recorder.Code)
		}
	}
}

func TestMediaHubContractAccessCarriesTheAccountsRights(t *testing.T) {
	seedRequestUser(t, 3, "lea")
	v1Stub(t, nil)
	recorder := httptest.NewRecorder()
	MediaHubRequestAccess(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/access", nil), nil, 3)
	var access mediahub.Access
	if err := json.Unmarshal(recorder.Body.Bytes(), &access); err != nil {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if access.Service != "mediahub" || !access.Linked || !access.Can.Request || access.Can.Moderate {
		t.Fatalf("droits = %+v", access)
	}
}

func TestOnyxHubOffersNoModeration(t *testing.T) {
	seedRequestUser(t, 1, "admin")
	hubStub(t, func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	recorder := httptest.NewRecorder()
	MediaHubAllRequests(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/all", nil), nil, 1)
	if recorder.Code != http.StatusNotImplemented {
		t.Fatalf("HTTP %d, attendu 501", recorder.Code)
	}
}

// postEvent envoie un évènement signé comme MediaHub le signe.
func postEvent(t *testing.T, body []byte, key, signKey string) *httptest.ResponseRecorder {
	t.Helper()
	signature := ""
	if signKey != "" {
		signature = "sha256=" + hex.EncodeToString(mediahub.Sign(body, signKey))
	}
	return postEventSigned(t, body, key, signature)
}

func postEventSigned(t *testing.T, body []byte, key, signature string) *httptest.ResponseRecorder {
	t.Helper()
	mediahub.Reset()
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/mediahub/events", bytes.NewReader(body))
	if key != "" {
		request.Header.Set("Authorization", "Bearer "+key)
	}
	if signature != "" {
		request.Header.Set("X-MediaHub-Signature", signature)
	}
	recorder := httptest.NewRecorder()
	MediaHubEvents(recorder, request, nil)
	return recorder
}

func TestMediaHubContractImportEventForgetsTheCachedStatus(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	mediaHubStatusCache.Put("1399", map[int]string{1: "processing"})
	if recorder := postEvent(t, mediaHubContract(t, "event_media_imported.json"), "cle", "cle"); recorder.Code != http.StatusAccepted {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if _, ok := mediaHubStatusCache.Get("1399"); ok {
		t.Fatal("le statut en cache aurait masqué la saison qui vient d'arriver")
	}
}

func TestMediaHubContractRequestEventsAreAccepted(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	for _, name := range []string{"event_request_created.json", "event_request_status_changed.json"} {
		mediaHubStatusCache.Put("1399", map[int]string{1: "pending"})
		if recorder := postEvent(t, mediaHubContract(t, name), "cle", "cle"); recorder.Code != http.StatusAccepted {
			t.Errorf("%s : HTTP %d : %s", name, recorder.Code, recorder.Body.String())
		}
		if _, ok := mediaHubStatusCache.Get("1399"); ok {
			t.Errorf("%s : statut en cache gardé", name)
		}
	}
}

func TestMediaHubEventsNeedTheKeyAndTheSignature(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	body := mediaHubContract(t, "event_media_imported.json")
	cases := map[string]*httptest.ResponseRecorder{
		"sans clé":           postEvent(t, body, "", "cle"),
		"mauvaise clé":       postEvent(t, body, "autre", "cle"),
		"sans signature":     postEvent(t, body, "cle", ""),
		"signé d'une autre":  postEvent(t, body, "cle", "autre"),
		"corps changé après": postEventSigned(t, append(bytes.Clone(body), ' '), "cle", "sha256="+hex.EncodeToString(mediahub.Sign(body, "cle"))),
	}
	for name, recorder := range cases {
		if recorder.Code != http.StatusUnauthorized {
			t.Errorf("%s : HTTP %d, attendu 401", name, recorder.Code)
		}
	}
}

func TestMediaHubEventsTolerateAnUnknownEvent(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	body := []byte(`{"id":"e-unknown","event":"request.renamed","apiVersion":1,"data":{}}`)
	if recorder := postEvent(t, body, "cle", "cle"); recorder.Code != http.StatusAccepted {
		t.Fatalf("HTTP %d, attendu 202 : une version plus récente de MediaHub peut en ajouter", recorder.Code)
	}
}

func TestMediaHubEventsAreAppliedOncePerDelivery(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	body := mediaHubContract(t, "event_media_imported.json")
	signature := "sha256=" + hex.EncodeToString(mediahub.Sign(body, "cle"))
	postEventSigned(t, body, "cle", signature)

	// MediaHub réessaie la même livraison : elle est acceptée sans être rejouée.
	mediaHubStatusCache.Put("1399", map[int]string{1: "processing"})
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/mediahub/events", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer cle")
	request.Header.Set("X-MediaHub-Signature", signature)
	recorder := httptest.NewRecorder()
	MediaHubEvents(recorder, request, nil)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("HTTP %d", recorder.Code)
	}
	if _, ok := mediaHubStatusCache.Get("1399"); !ok {
		t.Fatal("la même livraison a été appliquée deux fois")
	}
}
