package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func TestLibraryListsAnswerNotModifiedWhenUnchanged(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "lea", false, models.DefaultPermissions())
	if _, err := database.DB.Exec(`INSERT INTO medias (type, title, file_path) VALUES ('movie', 'Film', '/m/film.mkv')`); err != nil {
		t.Fatal(err)
	}

	get := func(ifNoneMatch string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/movies", nil)
		if ifNoneMatch != "" {
			req.Header.Set("If-None-Match", ifNoneMatch)
		}
		rec := httptest.NewRecorder()
		GetMovies(rec, req, nil, userID)
		return rec
	}

	first := get("")
	etag := first.Header().Get("ETag")
	if first.Code != http.StatusOK || etag == "" || first.Body.Len() == 0 {
		t.Fatalf("first fetch: %d, etag %q", first.Code, etag)
	}

	again := get(etag)
	if again.Code != http.StatusNotModified || again.Body.Len() != 0 {
		t.Fatalf("unchanged catalog: status %d with %d bytes, want 304 and nothing", again.Code, again.Body.Len())
	}

	// La progression du compte fait partie du document : la changer le change.
	if _, err := database.DB.Exec(`INSERT INTO progressions (user_id, media_id, current_position_seconds) SELECT ?, id, 120 FROM medias`, userID); err != nil {
		t.Fatal(err)
	}
	if changed := get(etag); changed.Code != http.StatusOK {
		t.Fatalf("after a progress change: status %d, want the new document", changed.Code)
	}
}

func TestEtagMatches(t *testing.T) {
	for header, want := range map[string]bool{
		`"abc"`:      true,
		`W/"abc"`:    true,
		`"x", "abc"`: true,
		`*`:          true,
		`"other"`:    false,
		``:           false,
	} {
		if got := etagMatches(header, `"abc"`); got != want {
			t.Errorf("If-None-Match %q: %v, want %v", header, got, want)
		}
	}
}
