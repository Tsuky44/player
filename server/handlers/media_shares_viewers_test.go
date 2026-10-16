package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

func listShares(t *testing.T, userID int) []models.MediaShare {
	t.Helper()
	rec := httptest.NewRecorder()
	ListMediaShares(rec, httptest.NewRequest(http.MethodGet, "/api/shares", nil), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("list shares: %d %s", rec.Code, rec.Body)
	}
	var out []models.MediaShare
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// Le créateur d'un lien voit qui le regarde et où chacun en est — le dernier
// épisode de chaque prénom, sa position ou « vu » — et rien des liens des
// autres (ADR-0066).
func TestShareLink_CreatorSeesWhereEachViewerIs(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	firstID := insertShareEpisode(t, shareSeasonID, 1, 1, "Pilote", "/s01e01.mkv")
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d}`, shareSeasonID))
	otherID := createTestUser(t, "other", false, models.AllPermissions())
	otherShare := createShare(t, otherID, fmt.Sprintf(`{"media_id":%d}`, episodeID))

	// Les lectures s'enchaînent dans la même milliseconde : chacune reçoit
	// son instant, pour que « le dernier regardé » ne dépende pas de l'horloge.
	clock := time.Date(2026, 10, 16, 20, 0, 0, 0, time.UTC)
	watch := func(code, name string, mediaID, position int) {
		t.Helper()
		var access models.SharedMediaAccess
		if status := callShared(t, OpenSharedMedia, map[string]any{
			"code": code, "media_id": mediaID, "name": name,
		}, &access); status != http.StatusOK {
			t.Fatalf("open for %s: %d", name, status)
		}
		if status := callShared(t, ReportSharedMediaProgress, map[string]any{
			"code": code, "viewer": access.Viewer, "ticket": access.Ticket,
			"media_id": mediaID, "name": name, "position_seconds": position, "duration_seconds": 3000,
		}, nil); status != http.StatusOK {
			t.Fatalf("progress for %s: %d", name, status)
		}
		clock = clock.Add(time.Minute)
		if _, err := database.DB.Exec(`UPDATE media_share_progress SET updated_at = ?
			WHERE viewer_name = ? AND media_id = ?`, clock.UnixMilli(), name, mediaID); err != nil {
			t.Fatalf("date %s's progress: %v", name, err)
		}
	}
	watch(share.Code, "Marie", firstID, 2950) // vu : au-delà de 90 %
	watch(share.Code, "Marie", episodeID, 600)
	watch(share.Code, "Paul", firstID, 2950)
	watch(otherShare.Code, "Zoé", episodeID, 300)

	shares := listShares(t, ownerID)
	if len(shares) != 1 || shares[0].ID != share.ID {
		t.Fatalf("owner shares = %+v", shares)
	}
	viewers := shares[0].Viewers
	if len(viewers) != 2 {
		t.Fatalf("viewers = %+v, want Paul then Marie", viewers)
	}
	paul, marie := viewers[0], viewers[1]
	if paul.Name != "Paul" || paul.MediaID != firstID || !paul.Finished || paul.PositionSeconds != 0 ||
		paul.SeasonNumber != 1 || paul.EpisodeNumber != 1 {
		t.Fatalf("paul = %+v", paul)
	}
	if marie.Name != "Marie" || marie.MediaID != episodeID || marie.Finished || marie.PositionSeconds != 600 ||
		marie.SeasonNumber != 1 || marie.EpisodeNumber != 5 || marie.Duration != 3000 ||
		!marie.WatchedAt.Equal(clock.Add(-2*time.Minute)) {
		t.Fatalf("marie = %+v", marie)
	}

	other := listShares(t, otherID)
	if len(other) != 1 || len(other[0].Viewers) != 1 || other[0].Viewers[0].Name != "Zoé" {
		t.Fatalf("other creator shares = %+v", other)
	}
}
