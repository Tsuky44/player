package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"project-player/server/database"
)

func TestLibraryTMDBIndexNamesTheOldestCopyOfEachTitle(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "tmdb_index.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
	insert := func(mediaType string, tmdbID int) int {
		t.Helper()
		res, err := database.DB.Exec(`INSERT INTO medias (type, title, tmdb_id) VALUES (?, 'x', ?)`, mediaType, tmdbID)
		if err != nil {
			t.Fatalf("insert %s: %v", mediaType, err)
		}
		id, _ := res.LastInsertId()
		return int(id)
	}
	matrix := insert("movie", 603)
	insert("movie", 603) // une seconde version du même film
	show := insert("show", 603)
	insert("movie", 0) // un fichier que TMDB n'a pas identifié
	insert("episode", 1399)

	recorder := httptest.NewRecorder()
	GetLibraryTMDBIndex(recorder, httptest.NewRequest(http.MethodGet, "/api/library/tmdb-index", nil), nil, 1)
	var index libraryTMDBIndex
	if err := json.NewDecoder(recorder.Body).Decode(&index); err != nil {
		t.Fatalf("décodage : %v (%s)", err, recorder.Body.String())
	}

	// Un film et une série de même identifiant TMDB restent distincts.
	if len(index.Movies) != 1 || index.Movies["603"] != matrix {
		t.Fatalf("films = %v, attendu 603 → %d", index.Movies, matrix)
	}
	if len(index.Shows) != 1 || index.Shows["603"] != show {
		t.Fatalf("séries = %v, attendu 603 → %d", index.Shows, show)
	}
}
