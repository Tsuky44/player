package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"testing"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

func TestLibraryShowEpisodesListsOnlyEpisodesWithAFile(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "show_episodes.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
	insert := func(query string, args ...any) int {
		t.Helper()
		res, err := database.DB.Exec(query, args...)
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
		id, _ := res.LastInsertId()
		return int(id)
	}
	season := func(show, number int) int {
		return insert(`INSERT INTO medias (type, title, parent_id, season_number) VALUES ('season', 's', ?, ?)`, show, number)
	}
	episode := func(season, number int, file string) {
		insert(`INSERT INTO medias (type, title, parent_id, episode_number, file_path) VALUES ('episode', 'e', ?, ?, ?)`, season, number, file)
	}
	show := insert(`INSERT INTO medias (type, title, tmdb_id) VALUES ('show', 'x', 1399)`)
	duplicate := insert(`INSERT INTO medias (type, title, tmdb_id) VALUES ('show', 'x bis', 1399)`)
	other := insert(`INSERT INTO medias (type, title, tmdb_id) VALUES ('show', 'y', 66)`)
	s1, s2, s1bis, s1other := season(show, 1), season(show, 2), season(duplicate, 1), season(other, 1)
	episode(s1, 2, "/a/2.mkv")
	episode(s1, 1, "/a/1.mkv")
	episode(s1, 3, "") // indexé sans fichier : pas lisible
	episode(s2, 5, "/a/s2e5.mkv")
	episode(s1bis, 2, "/b/2.mkv") // même épisode dans un second dossier
	episode(s1bis, 4, "/b/4.mkv")
	episode(s1other, 9, "/c/9.mkv") // une autre série

	recorder := httptest.NewRecorder()
	GetLibraryShowEpisodes(recorder, httptest.NewRequest(http.MethodGet, "/api/library/shows/1399/episodes", nil), httprouter.Params{{Key: "tmdb", Value: "1399"}}, 1)
	var got libraryShowEpisodes
	if err := json.NewDecoder(recorder.Body).Decode(&got); err != nil {
		t.Fatalf("décodage : %v (%s)", err, recorder.Body.String())
	}
	want := map[string][]int{"1": {1, 2, 4}, "2": {5}}
	if !reflect.DeepEqual(got.Seasons, want) {
		t.Fatalf("saisons = %v, attendu %v", got.Seasons, want)
	}

	recorder = httptest.NewRecorder()
	GetLibraryShowEpisodes(recorder, httptest.NewRequest(http.MethodGet, "/", nil), httprouter.Params{{Key: "tmdb", Value: "abc"}}, 1)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("identifiant invalide : HTTP %d, attendu 400", recorder.Code)
	}
}
