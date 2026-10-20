package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func postImport(t *testing.T, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/onyxhub/imported", strings.NewReader(body))
	if key != "" {
		request.Header.Set("Authorization", "Bearer "+key)
	}
	recorder := httptest.NewRecorder()
	OnyxHubImported(recorder, request, nil)
	return recorder
}

func TestImportSignalNeedsTheIntegrationKey(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	for name, key := range map[string]string{"sans clé": "", "mauvaise clé": "autre"} {
		if code := postImport(t, key, `{"tmdbId":603}`).Code; code != http.StatusUnauthorized {
			t.Errorf("%s : HTTP %d, attendu 401", name, code)
		}
	}

	// Un Onyx sans clé enregistrée n'accepte personne, même une clé vide.
	t.Setenv("MEDIAHUB_API_KEY", "")
	if code := postImport(t, "", `{}`).Code; code != http.StatusUnauthorized {
		t.Errorf("sans clé enregistrée : HTTP %d, attendu 401", code)
	}
}

func TestImportSignalForgetsTheCachedStatusOfTheTitle(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	mediaHubStatusCache.Put("1399", map[int]string{1: "processing"})

	recorder := postImport(t, "cle", `{"tmdbId":1399,"mediaType":"tv","paths":["/series/GoT/S01/e1.mkv"]}`)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("HTTP %d : %s", recorder.Code, recorder.Body.String())
	}
	if _, ok := mediaHubStatusCache.Get("1399"); ok {
		t.Fatal("le statut en cache aurait masqué la saison qui vient d'arriver")
	}
}

func TestImportSignalRefusesAnOversizedBatch(t *testing.T) {
	t.Setenv("MEDIAHUB_API_KEY", "cle")
	paths := strings.Repeat(`"/x.mkv",`, maxImportPaths) + `"/x.mkv"`
	if code := postImport(t, "cle", `{"paths":[`+paths+`]}`).Code; code != http.StatusBadRequest {
		t.Fatalf("HTTP %d, attendu 400", code)
	}
}
