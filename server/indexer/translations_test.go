package indexer

import (
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/medialang"
)

// fakeTMDB répond aux fiches et saisons en anglais, et compte les appels.
func fakeTMDB(t *testing.T, calls *[]string) {
	t.Helper()
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		*calls = append(*calls, r.URL.Path+"?language="+r.URL.Query().Get("language"))
		body, status := `{}`, http.StatusOK
		switch r.URL.Path {
		case "/3/movie/238":
			body = `{"title":"The Godfather","overview":"A crime family."}`
		case "/3/tv/1399":
			body = `{"name":"Game of Thrones","overview":"Seven kingdoms."}`
		case "/3/tv/1399/season/1":
			body = `{"episodes":[{"episode_number":1,"name":"Winter Is Coming","overview":"A king rides north."}]}`
		default:
			status = http.StatusNotFound
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old })
}

func seedLibraryToTranslate(t *testing.T) {
	t.Helper()
	for _, q := range []string{
		// Deux versions du même film : une seule identité TMDB.
		`INSERT INTO medias (id,type,title,tmdb_id,file_path) VALUES (1,'movie','Le Parrain',238,'a.mkv')`,
		`INSERT INTO medias (id,type,title,tmdb_id,file_path) VALUES (2,'movie','Le Parrain',238,'b.mkv')`,
		`INSERT INTO medias (id,type,title,tmdb_id) VALUES (3,'show','Le Trône de fer',1399)`,
		`INSERT INTO medias (id,type,title,parent_id,season_number) VALUES (4,'season','Saison 1',3,1)`,
		`INSERT INTO medias (id,type,title,parent_id,season_number,episode_number) VALUES (5,'episode','L''hiver vient',4,1,1)`,
		// Un épisode que TMDB ne connaît pas dans cette saison.
		`INSERT INTO medias (id,type,title,parent_id,season_number,episode_number) VALUES (6,'episode','Bonus',4,1,99)`,
		// Jamais identifié : rien à demander.
		`INSERT INTO medias (id,type,title,file_path) VALUES (7,'movie','Inconnu','c.mkv')`,
	} {
		if _, err := database.DB.Exec(q); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
}

// Les fiches identifiées reçoivent leur titre et leur synopsis dans l'autre
// langue de l'interface : un appel par identité, un par saison.
func TestTranslateMissingFillsTheOtherInterfaceLanguage(t *testing.T) {
	setupMovieDB(t)
	t.Setenv("TMDB_API_KEY", "test-key")
	t.Setenv("TMDB_LANGUAGE", "")
	var calls []string
	fakeTMDB(t, &calls)
	seedLibraryToTranslate(t)

	translateMissing()

	want := []string{
		"/3/movie/238?language=en-US",
		"/3/tv/1399?language=en-US",
		"/3/tv/1399/season/1?language=en-US",
	}
	if strings.Join(calls, " ") != strings.Join(want, " ") {
		t.Fatalf("TMDB calls = %v, want %v", calls, want)
	}

	texts, err := medialang.Texts("en", []int{1, 2, 3, 5, 6, 7})
	if err != nil {
		t.Fatal(err)
	}
	if texts[1].Title != "The Godfather" || texts[2].Title != "The Godfather" {
		t.Errorf("movie versions = %+v / %+v", texts[1], texts[2])
	}
	if texts[3].Title != "Game of Thrones" || texts[3].Overview != "Seven kingdoms." {
		t.Errorf("show = %+v", texts[3])
	}
	if texts[5].Title != "Winter Is Coming" {
		t.Errorf("episode = %+v", texts[5])
	}
	if text, ok := texts[6]; !ok || text.Title != "" {
		t.Errorf("unknown episode = %+v (present %v), want an empty settled row", text, ok)
	}
	if _, ok := texts[7]; ok {
		t.Errorf("an unidentified movie got a translation")
	}
}

// Un second passage ne redemande rien, épisode inconnu de TMDB compris.
func TestTranslateMissingAsksOnlyOnce(t *testing.T) {
	setupMovieDB(t)
	t.Setenv("TMDB_API_KEY", "test-key")
	t.Setenv("TMDB_LANGUAGE", "")
	var calls []string
	fakeTMDB(t, &calls)
	seedLibraryToTranslate(t)

	translateMissing()
	calls = nil
	translateMissing()

	if len(calls) != 0 {
		t.Fatalf("second pass made %d TMDB calls: %v", len(calls), calls)
	}
}

// Une fiche ré-identifiée est redemandée sous sa nouvelle identité.
func TestTranslateMissingRefetchesARematchedTitle(t *testing.T) {
	setupMovieDB(t)
	t.Setenv("TMDB_API_KEY", "test-key")
	t.Setenv("TMDB_LANGUAGE", "")
	var calls []string
	fakeTMDB(t, &calls)
	if _, err := database.DB.Exec(
		`INSERT INTO medias (id,type,title,tmdb_id,file_path) VALUES (1,'movie','Mauvais film',999,'a.mkv')`,
	); err != nil {
		t.Fatal(err)
	}
	translateMissing()

	if _, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 238 WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	calls = nil
	translateMissing()

	if len(calls) != 1 || calls[0] != "/3/movie/238?language=en-US" {
		t.Fatalf("calls after rematch = %v", calls)
	}
	texts, _ := medialang.Texts("en", []int{1})
	if texts[1].Title != "The Godfather" {
		t.Errorf("title after rematch = %q", texts[1].Title)
	}
}

// Une traduction vide réglait la question pour toujours : l'épisode importé le
// jour de sa diffusion gardait à vie « Episode 5 » sans synopsis. Une ligne
// incomplète se redemande tant que la fiche est récente, pas au-delà.
func TestIncompleteTranslationIsRetriedWhileTheMediaIsRecent(t *testing.T) {
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })

	for _, q := range []string{
		// 1 : récente, traduction incomplète d'avant-hier → à refaire.
		`INSERT INTO medias (id,type,title,tmdb_id,created_at) VALUES (1,'movie','Récent',101,datetime('now','-3 days'))`,
		`INSERT INTO media_translations (media_id,language,source_tmdb_id,title,overview,fetched_at) VALUES (1,'en',101,'Recent','',datetime('now','-2 days'))`,
		// 2 : récente, mais demandée il y a une heure → pas deux fois par jour.
		`INSERT INTO medias (id,type,title,tmdb_id,created_at) VALUES (2,'movie','Ce matin',102,datetime('now','-3 days'))`,
		`INSERT INTO media_translations (media_id,language,source_tmdb_id,title,overview,fetched_at) VALUES (2,'en',102,'','',datetime('now','-1 hour'))`,
		// 3 : ancienne, redemandée bien après ses soixante jours → réglée.
		`INSERT INTO medias (id,type,title,tmdb_id,created_at) VALUES (3,'movie','Ancien',103,datetime('now','-400 days'))`,
		`INSERT INTO media_translations (media_id,language,source_tmdb_id,title,overview,fetched_at) VALUES (3,'en',103,'Old','',datetime('now','-30 days'))`,
		// 4 : complète → réglée, quel que soit son âge.
		`INSERT INTO medias (id,type,title,tmdb_id,created_at) VALUES (4,'movie','Complet',104,datetime('now','-3 days'))`,
		`INSERT INTO media_translations (media_id,language,source_tmdb_id,title,overview,fetched_at) VALUES (4,'en',104,'Complete','All of it.',datetime('now','-20 days'))`,
	} {
		if _, err := database.DB.Exec(q); err != nil {
			t.Fatal(err)
		}
	}

	queue, err := loadTitlesToTranslate("en")
	if err != nil {
		t.Fatal(err)
	}
	if len(queue) != 1 || queue[0].id != 1 {
		t.Fatalf("queue = %+v, want only the recent media with an incomplete translation", queue)
	}
}
