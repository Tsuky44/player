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

// Une série dont aucun épisode n'a de fichier n'a rien à faire lire.
func TestCreateMediaShare_RefusesUnplayableMedia(t *testing.T) {
	ownerID, _ := setupShareTest(t)
	res, err := database.DB.Exec(`INSERT INTO medias (type, title) VALUES ('show', 'Annoncée')`)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	emptyShowID, _ := res.LastInsertId()
	seasonID := insertShareSeason(t, int(emptyShowID), 1)
	insertShareEpisode(t, seasonID, 1, 1, "Pas encore là", "")

	for _, mediaID := range []int{int(emptyShowID), seasonID, 9999} {
		rec := httptest.NewRecorder()
		CreateMediaShare(rec, httptest.NewRequest(http.MethodPost, "/api/shares",
			strings.NewReader(fmt.Sprintf(`{"media_id":%d}`, mediaID))), nil, ownerID)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("sharing media %d with nothing to play: %d, want 404", mediaID, rec.Code)
		}
	}
}

// shareShowID et shareSeasonID sont la série et la saison que setupShareTest
// crée en premier, dans une base neuve.
const (
	shareShowID   = 1
	shareSeasonID = 2
)

func insertShareSeason(t *testing.T, showID, number int) int {
	t.Helper()
	res, err := database.DB.Exec(`INSERT INTO medias (type, title, parent_id, season_number) VALUES ('season', ?, ?, ?)`,
		fmt.Sprintf("Season %d", number), showID, number)
	if err != nil {
		t.Fatalf("insert season: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func insertShareEpisode(t *testing.T, seasonID, season, episode int, title, filePath string) int {
	t.Helper()
	res, err := database.DB.Exec(`
		INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number)
		VALUES ('episode', ?, ?, 3000, ?, ?, ?)`, title, filePath, seasonID, season, episode)
	if err != nil {
		t.Fatalf("insert episode: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func sharedEpisodeIDs(media models.SharedMedia) []int {
	ids := make([]int, 0, len(media.Episodes))
	for _, episode := range media.Episodes {
		ids = append(ids, episode.ID)
	}
	return ids
}

// Le lien d'une saison ouvre ses épisodes, un ticket par épisode, et rien
// d'autre de la médiathèque : ni une autre saison, ni la saison elle-même.
func TestShareLink_SeasonOpensOnlyItsOwnEpisodes(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	firstID := insertShareEpisode(t, shareSeasonID, 1, 1, "Pilote", "/s01e01.mkv")
	otherSeasonID := insertShareSeason(t, shareShowID, 2)
	outsideID := insertShareEpisode(t, otherSeasonID, 2, 1, "Retour", "/s02e01.mkv")

	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d}`, shareSeasonID))
	if share.MediaType != "season" || share.Title != "Lioness" || share.Subtitle != "Saison 1" || share.PosterURL != "/show.jpg" {
		t.Fatalf("created share = %+v", share)
	}

	var info models.SharedMedia
	if status := callShared(t, SharedMediaInfo, map[string]string{"code": share.Code}, &info); status != http.StatusOK {
		t.Fatalf("info: %d", status)
	}
	if got := sharedEpisodeIDs(info); len(got) != 2 || got[0] != firstID || got[1] != episodeID {
		t.Fatalf("episodes = %v, want [%d %d]", got, firstID, episodeID)
	}

	var access models.SharedMediaAccess
	if status := callShared(t, OpenSharedMedia, map[string]any{"code": share.Code, "media_id": episodeID}, &access); status != http.StatusOK {
		t.Fatalf("open an episode of the season: %d", status)
	}
	if access.MediaID != episodeID || access.Media.Subtitle != "S01E05 · Cinq cent enfants" || len(access.Media.Episodes) != 0 {
		t.Fatalf("access = %+v", access)
	}
	if _, ok := PlaybackTickets.Validate(access.Ticket, episodeID); !ok {
		t.Fatal("the ticket does not open the chosen episode")
	}
	if _, ok := PlaybackTickets.Validate(access.Ticket, firstID); ok {
		t.Fatal("the ticket of one episode opens another")
	}

	if status := callShared(t, OpenSharedMedia, map[string]any{"code": share.Code, "media_id": outsideID}, nil); status != http.StatusNotFound {
		t.Fatalf("episode of another season: %d, want 404", status)
	}
	if status := callShared(t, OpenSharedMedia, map[string]any{"code": share.Code}, nil); status != http.StatusNotFound {
		t.Fatalf("season opened without choosing an episode: %d, want 404", status)
	}

	// Les routes de la lecture suivent l'épisode du ticket, pas l'id du lien.
	var progress models.SharedMediaProgress
	if status := callShared(t, ReportSharedMediaProgress, map[string]any{
		"code": share.Code, "viewer": access.Viewer, "ticket": access.Ticket, "media_id": episodeID, "position_seconds": 2990,
	}, &progress); status != http.StatusOK || progress.Consumed {
		t.Fatalf("progress on a season link: %d consumed=%v", status, progress.Consumed)
	}
	if status := callShared(t, ReportSharedMediaProgress, map[string]any{
		"code": share.Code, "viewer": access.Viewer, "ticket": access.Ticket, "media_id": firstID, "position_seconds": 10,
	}, nil); status != http.StatusUnauthorized {
		t.Fatalf("progress for an episode the ticket does not play: %d, want 401", status)
	}
}

// Le lien d'une série liste tous ses épisodes lisibles, dans l'ordre, et ne
// les montre qu'une fois le mot de passe donné.
func TestShareLink_ShowListsItsPlayableEpisodesBehindThePassword(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	otherSeasonID := insertShareSeason(t, shareShowID, 2)
	laterID := insertShareEpisode(t, otherSeasonID, 2, 1, "Retour", "/s02e01.mkv")
	insertShareEpisode(t, otherSeasonID, 2, 2, "Pas encore là", "")
	firstID := insertShareEpisode(t, shareSeasonID, 1, 1, "Pilote", "/s01e01.mkv")

	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d,"password":"popcorn"}`, shareShowID))
	if share.MediaType != "show" || share.Title != "Lioness" || share.Subtitle != "Série entière" {
		t.Fatalf("created share = %+v", share)
	}

	var info models.SharedMedia
	callShared(t, SharedMediaInfo, map[string]string{"code": share.Code}, &info)
	if !info.NeedsPassword || info.Title != "" || len(info.Episodes) != 0 {
		t.Fatalf("info leaks the show before the password: %+v", info)
	}
	if status := callShared(t, SharedMediaContents, map[string]string{"code": share.Code, "password": "nope"}, nil); status != http.StatusUnauthorized {
		t.Fatalf("contents with a wrong password: %d, want 401", status)
	}

	var contents models.SharedMedia
	if status := callShared(t, SharedMediaContents, map[string]string{"code": share.Code, "password": "popcorn"}, &contents); status != http.StatusOK {
		t.Fatalf("contents: %d", status)
	}
	got := sharedEpisodeIDs(contents)
	if len(got) != 3 || got[0] != firstID || got[1] != episodeID || got[2] != laterID {
		t.Fatalf("episodes = %v, want [%d %d %d]", got, firstID, episodeID, laterID)
	}
	if contents.Title != "Lioness" || contents.Episodes[2].SeasonNumber != 2 || contents.Episodes[2].Title != "Retour" {
		t.Fatalf("contents = %+v", contents)
	}
	if status := callShared(t, OpenSharedMedia, map[string]any{"code": share.Code, "password": "popcorn", "media_id": laterID}, nil); status != http.StatusOK {
		t.Fatalf("open an episode of the show: %d", status)
	}
}

// « Détruit après lecture » ne vaut que pour un seul média.
func TestCreateMediaShare_SeasonOrShowCannotBeSingleUse(t *testing.T) {
	ownerID, _ := setupShareTest(t)
	for _, mediaID := range []int{shareShowID, shareSeasonID} {
		rec := httptest.NewRecorder()
		CreateMediaShare(rec, httptest.NewRequest(http.MethodPost, "/api/shares",
			strings.NewReader(fmt.Sprintf(`{"media_id":%d,"single_use":true}`, mediaID))), nil, ownerID)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("single-use link on media %d: %d, want 400", mediaID, rec.Code)
		}
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

// Les pistes d'un lien protégé ne se lisent qu'avec un ticket du lien : le
// code seul ne prouve pas que le mot de passe a été donné.
func TestSharedMediaTracks_NeedsTheLinksTicket(t *testing.T) {
	ownerID, episodeID := setupShareTest(t)
	share := createShare(t, ownerID, fmt.Sprintf(`{"media_id":%d,"password":"popcorn"}`, episodeID))
	if status := callShared(t, SharedMediaTracks, map[string]string{"code": share.Code, "ticket": "forged"}, nil); status != http.StatusUnauthorized {
		t.Fatalf("tracks without a ticket: %d, want 401", status)
	}
	var access models.SharedMediaAccess
	callShared(t, OpenSharedMedia, map[string]string{"code": share.Code, "password": "popcorn"}, &access)
	// Le fichier de l'épisode n'existe pas ici : passé le contrôle d'accès,
	// c'est GetMediaTracks qui répond, et il répond 404.
	if status := callShared(t, SharedMediaTracks, map[string]string{"code": share.Code, "viewer": access.Viewer, "ticket": access.Ticket}, nil); status != http.StatusNotFound {
		t.Fatalf("tracks with the ticket: %d, want 404 from GetMediaTracks", status)
	}
}
