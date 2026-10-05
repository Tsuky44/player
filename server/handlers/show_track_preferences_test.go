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

// episodeIDs renvoie les épisodes d'une série semée par seedShow, dans l'ordre.
func episodeIDs(t *testing.T, showTitle string) []int {
	t.Helper()
	rows, err := database.DB.Query(
		`SELECT id FROM medias WHERE type = 'episode' AND title LIKE ? ORDER BY episode_number`,
		showTitle+" S%")
	if err != nil {
		t.Fatalf("list episodes of %q: %v", showTitle, err)
	}
	defer rows.Close()
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan episode id: %v", err)
		}
		ids = append(ids, id)
	}
	return ids
}

func episodeParam(mediaID int) httprouter.Params {
	return httprouter.Params{{Key: "id", Value: strconv.Itoa(mediaID)}}
}

func getShowTrackPreferences(t *testing.T, userID, mediaID int) models.ShowTrackPreferences {
	t.Helper()
	rec := httptest.NewRecorder()
	GetShowTrackPreferences(rec, httptest.NewRequest(http.MethodGet, "/", nil), episodeParam(mediaID), userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("get show track preferences: status %d", rec.Code)
	}
	var prefs models.ShowTrackPreferences
	if err := json.NewDecoder(rec.Body).Decode(&prefs); err != nil {
		t.Fatalf("decode show track preferences: %v", err)
	}
	return prefs
}

func putShowTrackPreferences(userID, mediaID int, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	UpdateShowTrackPreferences(rec, httptest.NewRequest(http.MethodPut, "/", strings.NewReader(body)),
		episodeParam(mediaID), userID)
	return rec
}

// Le choix fait dans un épisode vaut pour toute la série : c'est ce qui le
// fait suivre à l'épisode suivant, sur un autre appareil comme le lendemain.
func TestShowTrackPreferencesChosenInOneEpisodeApplyToTheWholeShow(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})
	seedShow(t, "Dark", 1, 0, 1, 2)
	seedShow(t, "Lupin", 2, 0, 1)
	dark := episodeIDs(t, "Dark")
	lupin := episodeIDs(t, "Lupin")

	body := `{"audio_lang":"EN","subtitle":{"mode":"on","lang":"fr","key":"fr2","forced":false,"image":false}}`
	if rec := putShowTrackPreferences(user, dark[0], body); rec.Code != http.StatusOK {
		t.Fatalf("put: status %d", rec.Code)
	}

	next := getShowTrackPreferences(t, user, dark[1])
	want := models.ShowSubtitleChoice{Mode: models.SubtitleModeOn, Lang: "fr", Key: "fr2"}
	if next.AudioLang != "en" || next.Subtitle != want || next.UpdatedAt == "" {
		t.Fatalf("next episode of the same show: got %+v", next)
	}
	if other := getShowTrackPreferences(t, user, lupin[0]); other.AudioLang != "" || other.Subtitle.Mode != "" || other.UpdatedAt != "" {
		t.Fatalf("another show inherited the choice: %+v", other)
	}
}

// Changer de sous-titre ne remet pas la langue audio à zéro, et inversement.
func TestShowTrackPreferencesPartialUpdateKeepsTheOtherChoice(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})
	seedShow(t, "Dark", 1, 0, 1)
	episode := episodeIDs(t, "Dark")[0]

	if rec := putShowTrackPreferences(user, episode, `{"audio_lang":"en"}`); rec.Code != http.StatusOK {
		t.Fatalf("put audio: status %d", rec.Code)
	}
	if rec := putShowTrackPreferences(user, episode, `{"subtitle":{"mode":"on","lang":"fr","key":"fr","forced":true}}`); rec.Code != http.StatusOK {
		t.Fatalf("put subtitle: status %d", rec.Code)
	}
	prefs := getShowTrackPreferences(t, user, episode)
	if prefs.AudioLang != "en" || !prefs.Subtitle.Forced || prefs.Subtitle.Lang != "fr" {
		t.Fatalf("after two partial updates: got %+v", prefs)
	}

	// « Désactivés » est un choix, pas une absence de choix : il ne garde
	// aucune piste et laisse l'audio tranquille.
	if rec := putShowTrackPreferences(user, episode, `{"subtitle":{"mode":"off","lang":"fr","forced":true}}`); rec.Code != http.StatusOK {
		t.Fatalf("put subtitles off: status %d", rec.Code)
	}
	prefs = getShowTrackPreferences(t, user, episode)
	if prefs.AudioLang != "en" || prefs.Subtitle != (models.ShowSubtitleChoice{Mode: models.SubtitleModeOff}) {
		t.Fatalf("after turning subtitles off: got %+v", prefs)
	}
}

func TestShowTrackPreferencesAreScopedToTheAccount(t *testing.T) {
	setupAuthDB(t)
	alice := createTestUser(t, "alice", false, models.Permissions{})
	bob := createTestUser(t, "bob", false, models.Permissions{})
	seedShow(t, "Dark", 1, 0, 1)
	episode := episodeIDs(t, "Dark")[0]

	if rec := putShowTrackPreferences(alice, episode, `{"audio_lang":"en"}`); rec.Code != http.StatusOK {
		t.Fatalf("put for alice: status %d", rec.Code)
	}
	if prefs := getShowTrackPreferences(t, bob, episode); prefs.AudioLang != "" || prefs.UpdatedAt != "" {
		t.Fatalf("bob sees alice's choice: %+v", prefs)
	}
}

func TestShowTrackPreferencesRejectInvalidInput(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})
	seedShow(t, "Dark", 1, 0, 1)
	seedMovies(t, 1)
	episode := episodeIDs(t, "Dark")[0]

	for _, body := range []string{
		`not json`,
		`{"audio_lang":"français"}`,
		`{"subtitle":{"mode":"maybe"}}`,
		`{"subtitle":{"mode":"on"}}`,
		`{"subtitle":{"mode":"on","lang":"fr","key":"../etc"}}`,
	} {
		if rec := putShowTrackPreferences(user, episode, body); rec.Code != http.StatusBadRequest {
			t.Errorf("body %q: status %d, want 400", body, rec.Code)
		}
	}
	if prefs := getShowTrackPreferences(t, user, episode); prefs.UpdatedAt != "" {
		t.Fatalf("a rejected update was stored: %+v", prefs)
	}

	// Un film n'appartient à aucune série : rien à retenir pour lui.
	var movieID int
	if err := database.DB.QueryRow(`SELECT id FROM medias WHERE type = 'movie' LIMIT 1`).Scan(&movieID); err != nil {
		t.Fatalf("find movie: %v", err)
	}
	if rec := putShowTrackPreferences(user, movieID, `{"audio_lang":"en"}`); rec.Code != http.StatusNotFound {
		t.Errorf("movie: status %d, want 404", rec.Code)
	}
}
