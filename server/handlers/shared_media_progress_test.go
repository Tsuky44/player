package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

// Deux personnes regardent la même saison par le même lien : chacune retrouve
// où elle en est sous son prénom, et seulement une fois le mot de passe donné.
func TestShareLink_EachViewerResumesUnderTheirOwnName(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	firstID := insertShareEpisode(t, shareSeasonID, 1, 1, "Pilote", "/s01e01.mkv")
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d,"password":"popcorn"}`, shareSeasonID))

	watch := func(name string, mediaID, position int) {
		t.Helper()
		var access models.SharedMediaAccess
		if status := callShared(t, OpenSharedMedia, map[string]any{
			"code": share.Code, "password": "popcorn", "media_id": mediaID, "name": name,
		}, &access); status != http.StatusOK {
			t.Fatalf("open for %s: %d", name, status)
		}
		if status := callShared(t, ReportSharedMediaProgress, map[string]any{
			"code": share.Code, "viewer": access.Viewer, "ticket": access.Ticket,
			"media_id": mediaID, "name": name, "position_seconds": position, "duration_seconds": 3000,
		}, nil); status != http.StatusOK {
			t.Fatalf("progress for %s: %d", name, status)
		}
	}
	watch("Marie", firstID, 2950) // vu : au-delà de 90 %
	watch("Marie", episodeID, 600)
	watch("Paul", firstID, 120)

	resume := func(name, password string) (models.SharedViewerProgress, int) {
		t.Helper()
		var out models.SharedViewerProgress
		status := callShared(t, SharedMediaResume, map[string]any{
			"code": share.Code, "password": password, "name": name,
		}, &out)
		return out, status
	}

	if _, status := resume("Marie", "wrong"); status != http.StatusUnauthorized {
		t.Fatalf("resume with a wrong password: %d, want 401", status)
	}
	marie, status := resume("marie", "popcorn")
	if status != http.StatusOK || marie.Name != "Marie" || marie.LastMediaID != episodeID ||
		marie.Positions[episodeID] != 600 || len(marie.Finished) != 1 || marie.Finished[0] != firstID {
		t.Fatalf("marie = %d %+v", status, marie)
	}
	paul, _ := resume("Paul", "popcorn")
	if paul.Positions[firstID] != 120 || paul.LastMediaID != firstID || len(paul.Finished) != 0 {
		t.Fatalf("paul = %+v", paul)
	}
	if _, status := resume("   ", "popcorn"); status != http.StatusBadRequest {
		t.Fatalf("resume without a name: %d, want 400", status)
	}

	// L'ouverture dit où reprendre, pour ce prénom-là.
	var access models.SharedMediaAccess
	callShared(t, OpenSharedMedia, map[string]any{
		"code": share.Code, "password": "popcorn", "media_id": episodeID, "name": "Marie",
	}, &access)
	if access.PositionSeconds != 600 {
		t.Fatalf("open position = %d, want 600", access.PositionSeconds)
	}
}

// Supprimer le lien efface où en étaient ses spectateurs : rien ne reste en
// base pour un lien qui n'existe plus.
func TestShareLink_DeletingTheLinkForgetsItsViewers(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d}`, episodeID))
	var access models.SharedMediaAccess
	callShared(t, OpenSharedMedia, map[string]any{"code": share.Code, "name": "Marie"}, &access)
	callShared(t, ReportSharedMediaProgress, map[string]any{
		"code": share.Code, "viewer": access.Viewer, "ticket": access.Ticket, "name": "Marie", "position_seconds": 600,
	}, nil)

	count := func() int {
		var n int
		if err := database.DB.QueryRow(`SELECT COUNT(*) FROM media_share_progress`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if count() != 1 {
		t.Fatalf("progress rows before delete = %d, want 1", count())
	}
	rec := httptest.NewRecorder()
	DeleteMediaShare(rec, httptest.NewRequest(http.MethodDelete, "/api/shares/1", nil), idParams(share.ID), ownerID)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body)
	}
	if n := count(); n != 0 {
		t.Fatalf("%d progress rows outlived the deleted link", n)
	}
}
