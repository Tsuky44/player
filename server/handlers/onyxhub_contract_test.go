package handlers

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/httpx"
)

// Le contrat avec OnyxHub, vu d'Onyx (ADR-0075).
//
// Les fichiers de contract/onyxhub/ sont des exemples réels des messages
// échangés. OnyxHub relit les mêmes fichiers dans son propre test de contrat :
// ce qu'Onyx écrit doit valoir ce fichier, et ce qu'OnyxHub écrit doit se
// lire ici sans rien perdre. Changer un format, c'est changer le fichier, puis
// faire passer les deux tests.

const onyxHubContractDir = "../../contract/onyxhub"

func onyxHubContract(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(onyxHubContractDir, name))
	if err != nil {
		t.Fatalf("contract/onyxhub/%s : %v", name, err)
	}
	return data
}

// sameJSON compare deux JSON par leur contenu : l'ordre des clés et la mise en
// page du fichier ne comptent pas.
func sameJSON(t *testing.T, name string, got []byte) {
	t.Helper()
	var want, have interface{}
	if err := json.Unmarshal(onyxHubContract(t, name), &want); err != nil {
		t.Fatalf("contract/onyxhub/%s illisible : %v", name, err)
	}
	if err := json.Unmarshal(got, &have); err != nil {
		t.Fatalf("%s : JSON produit illisible : %v (%s)", name, err, got)
	}
	if !reflect.DeepEqual(want, have) {
		t.Fatalf("Onyx ne produit plus contract/onyxhub/%s : OnyxHub lit ce format-là.\nObtenu : %s", name, got)
	}
}

func TestOnyxHubContractCatalogPageGoesOutAndComesBackInOneCall(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		sameJSON(t, "availability_batch_request.json", body)
		_, _ = w.Write(onyxHubContract(t, "availability_batch.json"))
	})
	items := []catalogItem{{ID: 603, MediaType: "movie"}, {ID: 1399, MediaType: "tv"}}
	enrichFromMediaHub(items)
	if items[0].Status != "available" || items[1].Status != "partial" {
		t.Fatalf("statuts lus = %q %q", items[0].Status, items[1].Status)
	}
}

func TestOnyxHubContractSingleAvailabilityKeepsSeasonStatuses(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(onyxHubContract(t, "availability.json"))
	})
	got := fetchMediaHubAvailability(1399, "tv", httpx.Fast)
	if got == nil || got.Status != "partial" || len(got.Seasons) != 2 || got.Seasons[1].Status != "processing" {
		t.Fatalf("disponibilité lue = %+v", got)
	}
}

func TestOnyxHubContractLinkTestReadsThePingAndAnswersTheSettingsScreen(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(onyxHubContract(t, "integration_ping.json"))
	})
	result, err := json.Marshal(probeMediaHub(os.Getenv("MEDIAHUB_URL"), "cle", httpx.Fast))
	if err != nil {
		t.Fatal(err)
	}
	sameJSON(t, "mediahub_link_test.json", result)
}

func TestOnyxHubContractImportAnnouncementIsAccepted(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/onyxhub/imported", bytes.NewReader(onyxHubContract(t, "imported.json")))
	request.Header.Set("Authorization", "Bearer cle")
	recorder := httptest.NewRecorder()
	OnyxHubImported(recorder, request, nil)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestOnyxHubContractLibraryIndex(t *testing.T) {
	got, err := json.Marshal(libraryTMDBIndex{Movies: map[string]int{"603": 12}, Shows: map[string]int{"1399": 40}})
	if err != nil {
		t.Fatal(err)
	}
	sameJSON(t, "library_tmdb_index.json", got)
}

func TestOnyxHubContractLibraryShowEpisodes(t *testing.T) {
	got, err := json.Marshal(libraryShowEpisodes{Seasons: map[string][]int{"1": {1, 2, 4}, "2": {5}}})
	if err != nil {
		t.Fatal(err)
	}
	sameJSON(t, "library_show_episodes.json", got)
}

func TestOnyxHubContractRequestIsRelayedAsSentWithTheAccount(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "contract.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	if _, err := database.DB.Exec(`INSERT INTO users (id, username, password_hash) VALUES (3, 'lea', 'x')`); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		sameJSON(t, "request.json", body)
		if r.Header.Get("X-Player-Username") != "lea" || r.Header.Get("X-Player-Id") != "3" {
			t.Errorf("compte transmis : %q / %q", r.Header.Get("X-Player-Username"), r.Header.Get("X-Player-Id"))
		}
		_, _ = w.Write([]byte(`{"success":true,"message":"ok"}`))
	})

	recorder := httptest.NewRecorder()
	MediaHubRequest(recorder, httptest.NewRequest(http.MethodPost, "/api/requests", strings.NewReader(string(onyxHubContract(t, "request.json")))), nil, 3)
	if recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}

func TestOnyxHubContractRequestFeedPassesTheCursorAndTheAnswerThrough(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "contract.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	if _, err := database.DB.Exec(`INSERT INTO users (id, username, password_hash) VALUES (1, 'admin', 'x')`); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/request/feed" || r.URL.RawQuery != "after=41" {
			t.Errorf("appel relayé : %s?%s", r.URL.Path, r.URL.RawQuery)
		}
		if r.Header.Get("X-Player-Id") != "1" {
			t.Errorf("compte transmis : %q", r.Header.Get("X-Player-Id"))
		}
		_, _ = w.Write(onyxHubContract(t, "request_feed.json"))
	})

	recorder := httptest.NewRecorder()
	MediaHubRequestFeed(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/feed?after=41&x=1", nil), nil, 1)
	if recorder.Code != http.StatusOK {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	sameJSON(t, "request_feed.json", recorder.Body.Bytes())
}

func TestRequestFeedRefusesACursorThatIsNotOneOnyxHubGave(t *testing.T) {
	recorder := httptest.NewRecorder()
	MediaHubRequestFeed(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/feed?after=-3", nil), nil, 1)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("HTTP %d, attendu 400", recorder.Code)
	}
}

func TestOnyxHubAvailabilityCarriesWhyARequestWaits(t *testing.T) {
	hubStub(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"pending","available":false,"seasons":[],"waiting":{"message":"Release non disponible au téléchargement · nouvelle tentative dans 42 min","nextAttemptAt":"2026-10-26T12:42:00Z"}}`))
	})
	got := fetchMediaHubAvailability(603, "movie", httpx.Fast)
	if got == nil || got.Waiting == nil || got.Waiting.Message != "Release non disponible au téléchargement · nouvelle tentative dans 42 min" {
		t.Fatalf("attente lue = %+v", got)
	}
}
