package handlers

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
)

func TestMyRequestsAreReadAtOnyxHubInTheNameOfTheAccount(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "my_requests.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	if _, err := database.DB.Exec(`INSERT INTO users (id, username, password_hash) VALUES (3, 'lea', 'x')`); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	hubStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/request" {
			t.Errorf("appel inattendu : %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("X-Player-Username") != "lea" || r.Header.Get("Authorization") != "Bearer cle" {
			t.Errorf("en-têtes = %v", r.Header)
		}
		_, _ = w.Write([]byte(`{"requests":[{"tmdbId":603,"mediaType":"movie","status":"processing","progress":40}]}`))
	})

	recorder := httptest.NewRecorder()
	MediaHubMyRequests(recorder, httptest.NewRequest(http.MethodGet, "/api/requests/mine", nil), nil, 3)

	// La réponse d'OnyxHub passe telle quelle : c'est son format que l'app lit.
	if recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), `"progress":40`) {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
}
