package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/playbackauth"
)

// setupShareTest ouvre une base avec un propriétaire qui a le droit de
// partager et un épisode lisible, et isole le store de tickets.
func setupShareTest(t *testing.T) (ownerID, episodeID int) {
	t.Helper()
	setupAuthDB(t)
	old := PlaybackTickets
	PlaybackTickets = playbackauth.NewStore()
	t.Cleanup(func() { PlaybackTickets = old })

	ownerID = createTestUser(t, "owner", true, models.AllPermissions())
	res, err := database.DB.Exec(`INSERT INTO medias (type, title, poster_url) VALUES ('show', 'Lioness', '/show.jpg')`)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	showID, _ := res.LastInsertId()
	res, err = database.DB.Exec(`INSERT INTO medias (type, title, parent_id, season_number) VALUES ('season', 'Saison 1', ?, 1)`, showID)
	if err != nil {
		t.Fatalf("insert season: %v", err)
	}
	seasonID, _ := res.LastInsertId()
	res, err = database.DB.Exec(`
		INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
		VALUES ('episode', 'Cinq cent enfants', '/ep.mkv', 3000, ?, 1, 5)`, seasonID)
	if err != nil {
		t.Fatalf("insert episode: %v", err)
	}
	id, _ := res.LastInsertId()
	return ownerID, int(id)
}

func createShare(t *testing.T, ownerID int, body string) models.MediaShare {
	t.Helper()
	rec := httptest.NewRecorder()
	CreateMediaShare(rec, httptest.NewRequest(http.MethodPost, "/api/shares", strings.NewReader(body)), nil, ownerID)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create share: %d %s", rec.Code, rec.Body)
	}
	var share models.MediaShare
	if err := json.Unmarshal(rec.Body.Bytes(), &share); err != nil {
		t.Fatal(err)
	}
	return share
}

// callShared appelle une route publique du visiteur et décode sa réponse.
func callShared(t *testing.T, handler httprouter.Handle, body any, out any) int {
	t.Helper()
	raw, _ := json.Marshal(body)
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest(http.MethodPost, "/api/shared", strings.NewReader(string(raw))), nil)
	if out != nil && rec.Code < 300 {
		if err := json.Unmarshal(rec.Body.Bytes(), out); err != nil {
			t.Fatalf("decode %s: %v", rec.Body, err)
		}
	}
	return rec.Code
}

func TestShareLink_SingleUseEpisodeIsDestroyedOnceWatched(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d,"single_use":true,"password":"popcorn","expires_in_hours":24}`, episodeID))
	if share.Code == "" || share.Title != "Lioness" || share.Subtitle != "S01E05 · Cinq cent enfants" || share.Status != "active" {
		t.Fatalf("created share = %+v", share)
	}
	code := share.Code

	// Avant le mot de passe, le lien ne dit pas ce qu'il ouvre.
	var info models.SharedMedia
	if status := callShared(t, SharedMediaInfo, map[string]string{"code": code}, &info); status != http.StatusOK {
		t.Fatalf("info: %d", status)
	}
	if !info.NeedsPassword || info.Title != "" {
		t.Fatalf("info leaks the media before the password: %+v", info)
	}
	if status := callShared(t, OpenSharedMedia, map[string]string{"code": code, "password": "nope"}, nil); status != http.StatusUnauthorized {
		t.Fatalf("wrong password: %d", status)
	}

	var access models.SharedMediaAccess
	if status := callShared(t, OpenSharedMedia, map[string]string{"code": code, "password": "popcorn"}, &access); status != http.StatusOK {
		t.Fatalf("open: %d", status)
	}
	if access.MediaID != episodeID || access.Viewer == "" || access.Media.Title != "Lioness" {
		t.Fatalf("access = %+v", access)
	}
	if _, ok := PlaybackTickets.Validate(access.Ticket, episodeID); !ok {
		t.Fatal("the ticket does not open the episode")
	}
	if status := callShared(t, OpenSharedMedia, map[string]string{"code": code, "password": "popcorn"}, nil); status != http.StatusConflict {
		t.Fatalf("second browser: %d, want 409", status)
	}

	progress := func(position int) models.SharedMediaProgress {
		var out models.SharedMediaProgress
		if status := callShared(t, ReportSharedMediaProgress, map[string]any{
			"code": code, "viewer": access.Viewer, "ticket": access.Ticket, "position_seconds": position,
		}, &out); status != http.StatusOK {
			t.Fatalf("progress %d: %d", position, status)
		}
		return out
	}
	if progress(1200).Consumed {
		t.Fatal("consumed at 40%")
	}
	if !progress(2750).Consumed {
		t.Fatal("not consumed past the watched threshold")
	}

	if status := callShared(t, SharedMediaInfo, map[string]string{"code": code, "viewer": access.Viewer}, nil); status != http.StatusGone {
		t.Fatalf("info after watched: %d, want 410", status)
	}
	// Le navigateur qui a vu le lien finit sa lecture.
	if status := callShared(t, RenewSharedMedia, map[string]string{"code": code, "viewer": access.Viewer, "ticket": access.Ticket}, nil); status != http.StatusOK {
		t.Fatalf("renew during the credits: %d", status)
	}
}

// Seul le navigateur qui lit peut détruire le lien : connaître le code ne
// suffit pas.
func TestShareLink_ProgressNeedsTheViewersTicket(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d,"single_use":true}`, episodeID))
	var access models.SharedMediaAccess
	callShared(t, OpenSharedMedia, map[string]string{"code": share.Code}, &access)

	if status := callShared(t, ReportSharedMediaProgress, map[string]any{
		"code": share.Code, "viewer": access.Viewer, "ticket": "forged", "position_seconds": 2990,
	}, nil); status != http.StatusUnauthorized {
		t.Fatalf("forged ticket: %d, want 401", status)
	}
	if status := callShared(t, SharedMediaInfo, map[string]string{"code": share.Code, "viewer": access.Viewer}, nil); status != http.StatusOK {
		t.Fatalf("link destroyed by a forged report: %d", status)
	}
}

func TestShareLink_DeleteCutsPlaybackImmediately(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d}`, episodeID))
	var access models.SharedMediaAccess
	callShared(t, OpenSharedMedia, map[string]string{"code": share.Code}, &access)

	rec := httptest.NewRecorder()
	DeleteMediaShare(rec, httptest.NewRequest(http.MethodDelete, "/api/shares/1", nil), idParams(share.ID), ownerID)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body)
	}
	if _, ok := PlaybackTickets.Validate(access.Ticket, episodeID); ok {
		t.Fatal("the ticket outlived its link")
	}
	if status := callShared(t, SharedMediaInfo, map[string]string{"code": share.Code}, nil); status != http.StatusNotFound {
		t.Fatalf("info after delete: %d, want 404", status)
	}
}

// Retirer le droit de partager retire aussi les liens qui circulent, comme
// pour les invitations.
func TestUpdateUserPermissions_RevokingShareRightKillsLinks(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	sharerID := createTestUser(t, "sister", false, models.Permissions{RequestMedia: true, ShareMedia: true})
	share := createShare(t, sharerID, fmt.Sprintf(`{"media_id":%d}`, episodeID))

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/x/permissions", strings.NewReader(`{"permissions":{"request_media":true}}`)),
		idParams(sharerID), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("permission update: %d %s", rec.Code, rec.Body)
	}
	if status := callShared(t, SharedMediaInfo, map[string]string{"code": share.Code}, nil); status != http.StatusNotFound {
		t.Fatalf("link survived the right: %d", status)
	}
}

func TestCreateMediaShare_RefusesUnplayableMedia(t *testing.T) {
	ownerID, _ := setupShareTest(t)
	rec := httptest.NewRecorder()
	CreateMediaShare(rec, httptest.NewRequest(http.MethodPost, "/api/shares", strings.NewReader(`{"media_id":1}`)), nil, ownerID)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("sharing a show: %d, want 404", rec.Code)
	}
}

func TestListMediaShares_OnlyTheCallersLinks(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	otherID := createTestUser(t, "other", false, models.Permissions{ShareMedia: true})
	createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d}`, episodeID))
	createShare(t, otherID, fmt.Sprintf(`{"media_id":%d,"single_use":true}`, episodeID))

	rec := httptest.NewRecorder()
	ListMediaShares(rec, httptest.NewRequest(http.MethodGet, "/api/shares", nil), nil, ownerID)
	var list []models.MediaShare
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].SingleUse || list[0].Code != "" || list[0].Title != "Lioness" {
		t.Fatalf("list = %+v", list)
	}
}
