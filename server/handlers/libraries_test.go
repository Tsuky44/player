package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/libraries"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

func libraryCall(t *testing.T, handle AuthenticatedHandle, method, body string, id, userID int) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, "/api/libraries", strings.NewReader(body))
	rec := httptest.NewRecorder()
	var ps httprouter.Params
	if id > 0 {
		ps = httprouter.Params{{Key: "id", Value: strconv.Itoa(id)}}
	}
	handle(rec, req, ps, userID)
	return rec
}

func libraryBody(t *testing.T, name string, kind libraries.Kind, path string) string {
	t.Helper()
	raw, err := json.Marshal(libraryRequest{Name: name, Kind: kind, Path: path})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func insertMediaRow(t *testing.T, mediaType, title, path string, parentID int) int {
	t.Helper()
	var parent, filePath interface{}
	if parentID > 0 {
		parent = parentID
	}
	if path != "" {
		filePath = path
	}
	res, err := database.DB.Exec(`INSERT INTO medias (type, title, file_path, parent_id) VALUES (?, ?, ?, ?)`,
		mediaType, title, filePath, parent)
	if err != nil {
		t.Fatalf("insert %s %q: %v", mediaType, title, err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func TestLibraryNamesAreFreeAndAsManyAsWanted(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())

	for _, name := range []string{"Vidéos de famille", "Conférences", "Courts-métrages"} {
		rec := libraryCall(t, CreateLibrary, http.MethodPost, libraryBody(t, name, libraries.KindMovies, t.TempDir()), 0, admin)
		if rec.Code != http.StatusCreated {
			t.Fatalf("create %q: %d %s", name, rec.Code, rec.Body.String())
		}
	}

	rec := libraryCall(t, ListLibraries, http.MethodGet, "", 0, admin)
	var libs []libraries.Library
	if err := json.Unmarshal(rec.Body.Bytes(), &libs); err != nil {
		t.Fatal(err)
	}
	if len(libs) != 3 || libs[0].Name != "Vidéos de famille" || libs[2].Name != "Courts-métrages" {
		t.Fatalf("libraries = %+v", libs)
	}
}

// Le dossier d'une bibliothèque est l'arborescence du disque du serveur : un
// compte qui ne peut pas la changer n'a pas à la lire.
func TestLibraryFoldersAreOnlyShownToWhoCanChangeThem(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())
	viewer := createTestUser(t, "lea", false, models.DefaultPermissions())
	dir := t.TempDir()
	if _, err := libraries.Create("Films", libraries.KindMovies, dir); err != nil {
		t.Fatal(err)
	}

	list := func(userID int) []libraries.Library {
		var libs []libraries.Library
		rec := libraryCall(t, ListLibraries, http.MethodGet, "", 0, userID)
		if err := json.Unmarshal(rec.Body.Bytes(), &libs); err != nil {
			t.Fatal(err)
		}
		return libs
	}
	if got := list(admin); len(got) != 1 || got[0].Path == "" {
		t.Fatalf("admin sees %+v, want the folder", got)
	}
	if got := list(viewer); len(got) != 1 || got[0].Path != "" || got[0].Name != "Films" {
		t.Fatalf("viewer sees %+v, want the name without the folder", got)
	}
}

func TestLibraryWritesAnswerWithAReasonTheAppCanShow(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())
	dir := t.TempDir()

	cases := []struct {
		label, body string
		want        int
	}{
		{"not json", "{", http.StatusBadRequest},
		{"no name", libraryBody(t, "", libraries.KindMovies, dir), http.StatusBadRequest},
		{"unknown kind", libraryBody(t, "Musique", "music", dir), http.StatusBadRequest},
		{"missing folder", libraryBody(t, "Films", libraries.KindMovies, dir+"-absent"), http.StatusBadRequest},
		{"valid", libraryBody(t, "Films", libraries.KindMovies, dir), http.StatusCreated},
		{"folder taken", libraryBody(t, "Bis", libraries.KindShows, dir), http.StatusConflict},
	}
	for _, c := range cases {
		rec := libraryCall(t, CreateLibrary, http.MethodPost, c.body, 0, admin)
		if rec.Code != c.want {
			t.Errorf("%s: status %d, want %d (%s)", c.label, rec.Code, c.want, rec.Body.String())
		}
		if c.want >= 400 && !strings.Contains(rec.Body.String(), `"error"`) {
			t.Errorf("%s: no error message in %s", c.label, rec.Body.String())
		}
	}

	if rec := libraryCall(t, UpdateLibrary, http.MethodPut, libraryBody(t, "X", "", dir), 999, admin); rec.Code != http.StatusNotFound {
		t.Errorf("update unknown library: %d, want 404", rec.Code)
	}
	if rec := libraryCall(t, DeleteLibrary, http.MethodDelete, "", 999, admin); rec.Code != http.StatusNotFound {
		t.Errorf("delete unknown library: %d, want 404", rec.Code)
	}
}

func TestRenamingALibraryKeepsItsCatalog(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())
	lib, err := libraries.Create("Films", libraries.KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	insertMediaRow(t, "movie", "Dune", lib.Path+"/Dune.mkv", 0)

	rec := libraryCall(t, UpdateLibrary, http.MethodPut, libraryBody(t, "Cinéma du dimanche", "", lib.Path), lib.ID, admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("rename: %d %s", rec.Code, rec.Body.String())
	}
	var updated libraries.Library
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Name != "Cinéma du dimanche" || updated.Kind != libraries.KindMovies {
		t.Fatalf("updated = %+v", updated)
	}
	var movies int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type = 'movie'`).Scan(&movies); err != nil {
		t.Fatal(err)
	}
	if movies != 1 {
		t.Fatalf("movies = %d after a rename, want 1", movies)
	}
}

// Un dossier qui arrive est analysé, un dossier qui part est oublié, et un
// simple changement de nom ne touche pas au catalogue.
func TestLibraryFolderChangesStartTheirBackgroundJobs(t *testing.T) {
	setupAuthDB(t)
	jobs := recordLibraryJobs(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())
	first, second := t.TempDir(), t.TempDir()

	rec := libraryCall(t, CreateLibrary, http.MethodPost, libraryBody(t, "Films", libraries.KindMovies, first), 0, admin)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body.String())
	}
	var lib libraries.Library
	if err := json.Unmarshal(rec.Body.Bytes(), &lib); err != nil {
		t.Fatal(err)
	}
	if jobs.scans != 1 || len(jobs.forgotten) != 0 {
		t.Fatalf("after a creation: %+v, want one scan", jobs)
	}

	if rec := libraryCall(t, UpdateLibrary, http.MethodPut, libraryBody(t, "Cinéma", "", lib.Path), lib.ID, admin); rec.Code != http.StatusOK {
		t.Fatalf("rename: %d %s", rec.Code, rec.Body.String())
	}
	if jobs.scans != 1 || len(jobs.forgotten) != 0 {
		t.Fatalf("after a rename: %+v, want nothing more", jobs)
	}

	rec = libraryCall(t, UpdateLibrary, http.MethodPut, libraryBody(t, "Cinéma", "", second), lib.ID, admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("move: %d %s", rec.Code, rec.Body.String())
	}
	var moved libraries.Library
	if err := json.Unmarshal(rec.Body.Bytes(), &moved); err != nil {
		t.Fatal(err)
	}
	if jobs.scans != 2 || len(jobs.forgotten) != 1 || jobs.forgotten[0] != lib.Path {
		t.Fatalf("after a move: %+v, want a second scan and %q forgotten", jobs, lib.Path)
	}

	if rec := libraryCall(t, DeleteLibrary, http.MethodDelete, "", lib.ID, admin); rec.Code != http.StatusNoContent {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body.String())
	}
	if jobs.scans != 2 || len(jobs.forgotten) != 2 || jobs.forgotten[1] != moved.Path {
		t.Fatalf("after a deletion: %+v, want %q forgotten and no scan", jobs, moved.Path)
	}
}

// Chaque liste du catalogue se lit par bibliothèque ; sans paramètre elle
// couvre tout le serveur, comme pour la recherche et les apps plus anciennes.
func TestCatalogListsAreScopedToALibrary(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "lea", false, models.DefaultPermissions())
	films, err := libraries.Create("Films", libraries.KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	concerts, err := libraries.Create("Concerts", libraries.KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	animes, err := libraries.Create("Animés", libraries.KindShows, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	series, err := libraries.Create("Séries", libraries.KindShows, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	slash := func(lib libraries.Library, rest string) string {
		lower, _ := libraries.PathRange(lib.Path)
		return lower + rest
	}
	insertMediaRow(t, "movie", "Dune", slash(films, "Dune (2021)/Dune.mkv"), 0)
	insertMediaRow(t, "movie", "Pompeii", slash(concerts, "Pompeii.mkv"), 0)
	for _, show := range []struct {
		title string
		lib   libraries.Library
	}{{"Naruto", animes}, {"Kaamelott", series}} {
		showID := insertMediaRow(t, "show", show.title, "", 0)
		seasonID := insertMediaRow(t, "season", "Saison 1", "", showID)
		insertMediaRow(t, "episode", "Épisode 1", slash(show.lib, show.title+"/S01E01.mkv"), seasonID)
	}

	titles := func(handle AuthenticatedHandle, query string) []string {
		t.Helper()
		rec := httptest.NewRecorder()
		handle(rec, httptest.NewRequest(http.MethodGet, "/api/list"+query, nil), nil, userID)
		if rec.Code != http.StatusOK {
			t.Fatalf("list%s: %d %s", query, rec.Code, rec.Body.String())
		}
		var rows []struct {
			Title string `json:"title"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &rows); err != nil {
			t.Fatal(err)
		}
		got := make([]string, 0, len(rows))
		for _, row := range rows {
			got = append(got, row.Title)
		}
		return got
	}
	expect := func(label string, got []string, want ...string) {
		t.Helper()
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("%s = %v, want %v", label, got, want)
		}
	}
	of := func(lib libraries.Library) string { return "?library=" + strconv.Itoa(lib.ID) }

	expect("every movie", titles(GetMovies, ""), "Dune", "Pompeii")
	expect("Films", titles(GetMovies, of(films)), "Dune")
	expect("Concerts", titles(GetMovies, of(concerts)), "Pompeii")
	expect("every show", titles(GetShows, ""), "Kaamelott", "Naruto")
	expect("Animés", titles(GetShows, of(animes)), "Naruto")
	expect("Séries", titles(GetShows, of(series)), "Kaamelott")

	for _, query := range []string{"?library=abc", "?library=999"} {
		rec := httptest.NewRecorder()
		GetMovies(rec, httptest.NewRequest(http.MethodGet, "/api/movies"+query, nil), nil, userID)
		if rec.Code != http.StatusBadRequest && rec.Code != http.StatusNotFound {
			t.Errorf("GetMovies%s: %d, want 400 or 404", query, rec.Code)
		}
	}
}

func TestPingAnnouncesLibraries(t *testing.T) {
	for _, capability := range pingPayload().Capabilities {
		if capability == CapabilityLibraries {
			return
		}
	}
	t.Fatal("the app reads this capability to know the server lists its libraries")
}

// L'accueil a une rangée par bibliothèque, sous le nom que l'administrateur lui
// a donné : aucun titre de rangée n'est écrit dans l'app.
func TestHomeHasARowPerLibraryUnderItsName(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "lea", false, models.DefaultPermissions())
	family, err := libraries.Create("Vidéos de famille", libraries.KindOther, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := libraries.Create("Vide", libraries.KindMovies, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	animes, err := libraries.Create("Animés", libraries.KindShows, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	under := func(lib libraries.Library, rest string) string {
		lower, _ := libraries.PathRange(lib.Path)
		return lower + rest
	}
	insertMediaRow(t, "movie", "Noël 2019", under(family, "Noël 2019.mp4"), 0)
	showID := insertMediaRow(t, "show", "Naruto", "", 0)
	seasonID := insertMediaRow(t, "season", "Saison 1", "", showID)
	insertMediaRow(t, "episode", "Épisode 1", under(animes, "Naruto/S01E01.mkv"), seasonID)

	rec := httptest.NewRecorder()
	Home(rec, httptest.NewRequest(http.MethodGet, "/api/home", nil), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("home: %d %s", rec.Code, rec.Body.String())
	}
	var home models.HomeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &home); err != nil {
		t.Fatal(err)
	}

	if len(home.Libraries) != 2 {
		t.Fatalf("rows = %+v, want one per library that holds something", home.Libraries)
	}
	first, second := home.Libraries[0], home.Libraries[1]
	if first.Name != "Vidéos de famille" || first.Kind != "other" || len(first.Items) != 1 || first.Items[0].Title != "Noël 2019" {
		t.Fatalf("first row = %+v", first)
	}
	if second.Name != "Animés" || second.ID != animes.ID || len(second.Items) != 1 || second.Items[0].Title != "Naruto" {
		t.Fatalf("second row = %+v", second)
	}
}

// Une vidéo d'une bibliothèque « autre » n'a pas d'identité à trouver : elle
// n'est pas un média « à vérifier ».
func TestPlainLibraryVideosAreNotQueuedForReview(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.AllPermissions())
	family, err := libraries.Create("Famille", libraries.KindOther, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	lower, _ := libraries.PathRange(family.Path)
	insertMediaRow(t, "movie", "Noël 2019", lower+"Noël 2019.mp4", 0)
	insertMediaRow(t, "movie", "Film inconnu", "/ailleurs/Film inconnu.mkv", 0)

	rec := httptest.NewRecorder()
	GetMediaReviewQueue(rec, httptest.NewRequest(http.MethodGet, "/api/indexer/review", nil), nil, admin)
	var queue mediaReviewResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &queue); err != nil {
		t.Fatal(err)
	}
	if queue.Count != 1 || queue.Items[0].Title != "Film inconnu" {
		t.Fatalf("review queue = %+v, want the unidentified film only", queue.Items)
	}
}
