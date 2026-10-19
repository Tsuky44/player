package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

func listParams(id int, more ...httprouter.Param) httprouter.Params {
	return append(httprouter.Params{{Key: "id", Value: strconv.Itoa(id)}}, more...)
}

func createList(t *testing.T, userID int, body string) models.WatchList {
	t.Helper()
	rec := httptest.NewRecorder()
	CreateWatchList(rec, httptest.NewRequest(http.MethodPost, "/api/lists", strings.NewReader(body)), nil, userID)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create list: status %d: %s", rec.Code, rec.Body.String())
	}
	var l models.WatchList
	if err := json.NewDecoder(rec.Body).Decode(&l); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	return l
}

func addToList(t *testing.T, userID, listID int, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	AddWatchListItem(rec, httptest.NewRequest(http.MethodPost, "/api/lists/x/items", strings.NewReader(body)),
		listParams(listID), userID)
	return rec
}

// La liste partagée se lit par un autre compte, avec la fiche du serveur et
// sa progression à lui ; un titre du catalogue y reste sous son instantané.
func TestSharedListShowsServerMediaWithTheReadersProgress(t *testing.T) {
	setupAuthDB(t)
	alice := createTestUser(t, "alice", false, models.Permissions{})
	bob := createTestUser(t, "bob", false, models.Permissions{})
	if _, err := database.DB.Exec(`INSERT INTO medias (id, type, title, file_path, duration, tmdb_id) VALUES (10, 'movie', 'Matrix', '/m.mkv', 8000, 603)`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.DB.Exec(`INSERT INTO progressions (user_id, media_id, current_position_seconds) VALUES (?, 10, 1200)`, bob); err != nil {
		t.Fatal(err)
	}

	recos := createList(t, alice, `{"name":"Mes recos","is_shared":true}`)
	if rec := addToList(t, alice, recos.ID, `{"media_id":10}`); rec.Code != http.StatusOK {
		t.Fatalf("add media: %d %s", rec.Code, rec.Body.String())
	}
	if rec := addToList(t, alice, recos.ID, `{"tmdb_id":1399,"media_type":"tv","title":"Game of Thrones","poster_path":"/got.jpg"}`); rec.Code != http.StatusOK {
		t.Fatalf("add catalog title: %d %s", rec.Code, rec.Body.String())
	}

	rec := httptest.NewRecorder()
	GetWatchList(rec, httptest.NewRequest(http.MethodGet, "/api/lists/x", nil), listParams(recos.ID), bob)
	if rec.Code != http.StatusOK {
		t.Fatalf("get shared list: %d %s", rec.Code, rec.Body.String())
	}
	var detail models.WatchListDetail
	if err := json.NewDecoder(rec.Body).Decode(&detail); err != nil {
		t.Fatal(err)
	}
	if detail.IsMine || len(detail.Items) != 2 {
		t.Fatalf("bob reads alice's two titles: %+v", detail)
	}
	got, media := detail.Items[0], detail.Items[1]
	if got.MediaID != 0 || got.Media != nil || got.Title != "Game of Thrones" {
		t.Fatalf("catalog title, latest first, not on the server: %+v", got)
	}
	if media.MediaID != 10 || media.Media == nil || media.Media.CurrentPositionSeconds != 1200 {
		t.Fatalf("server media with bob's progress: %+v", media)
	}
}

func TestWatchListRoutesAnswerWithTheRightStatus(t *testing.T) {
	setupAuthDB(t)
	alice := createTestUser(t, "alice", false, models.Permissions{})
	bob := createTestUser(t, "bob", false, models.Permissions{})
	private := createList(t, alice, `{"name":"Secret"}`)
	shared := createList(t, alice, `{"name":"Recos","is_shared":true}`)

	rec := httptest.NewRecorder()
	GetWatchList(rec, httptest.NewRequest(http.MethodGet, "/api/lists/x", nil), listParams(private.ID), bob)
	if rec.Code != http.StatusNotFound {
		t.Errorf("private list for another account: %d, want 404", rec.Code)
	}
	if rec := addToList(t, bob, shared.ID, `{"tmdb_id":1,"media_type":"movie","title":"X"}`); rec.Code != http.StatusForbidden {
		t.Errorf("write to someone else's shared list: %d, want 403", rec.Code)
	}
	if rec := addToList(t, alice, shared.ID, `{"tmdb_id":1,"media_type":"movie","title":"X","poster_path":"https://evil.example/p.jpg"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("foreign poster: %d, want 400", rec.Code)
	}

	rec = httptest.NewRecorder()
	ListWatchLists(rec, httptest.NewRequest(http.MethodGet, "/api/lists", nil), nil, alice)
	var lists models.WatchListsResponse
	if err := json.NewDecoder(rec.Body).Decode(&lists); err != nil {
		t.Fatal(err)
	}
	later := lists.Mine[0]
	rec = httptest.NewRecorder()
	DeleteWatchList(rec, httptest.NewRequest(http.MethodDelete, "/api/lists/x", nil), listParams(later.ID), alice)
	if rec.Code != http.StatusConflict {
		t.Errorf("delete watch later: %d, want 409", rec.Code)
	}

	rec = httptest.NewRecorder()
	ListWatchLists(rec, httptest.NewRequest(http.MethodGet, "/api/lists?media_id=abc&tmdb_id=x", nil), nil, alice)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("unreadable probe: %d, want 400", rec.Code)
	}
}
