package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/models"
)

func getPlaybackPreferences(t *testing.T, userID int) models.PlaybackPreferences {
	t.Helper()
	rec := httptest.NewRecorder()
	GetPlaybackPreferences(rec, httptest.NewRequest(http.MethodGet, "/api/me/playback-preferences", nil), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("get playback preferences: status %d", rec.Code)
	}
	var prefs models.PlaybackPreferences
	if err := json.NewDecoder(rec.Body).Decode(&prefs); err != nil {
		t.Fatalf("decode playback preferences: %v", err)
	}
	return prefs
}

func putPlaybackPreferences(userID int, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	UpdatePlaybackPreferences(rec, httptest.NewRequest(http.MethodPut, "/api/me/playback-preferences",
		strings.NewReader(body)), nil, userID)
	return rec
}

// Un compte qui n'a rien enregistré le dit par un updated_at vide : c'est ce
// qui autorise le premier appareil à y déposer ses réglages locaux.
func TestPlaybackPreferencesUnsavedAccountReportsEmptyUpdatedAt(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})

	prefs := getPlaybackPreferences(t, user)
	if prefs.UpdatedAt != "" || prefs.AutoSkipIntro || prefs.DefaultAudioLang != "" {
		t.Fatalf("unsaved account: got %+v, want defaults with empty updated_at", prefs)
	}
}

// Une mise à jour partielle ne touche que les champs envoyés : le réglage posé
// depuis un appareil ne remet pas à zéro celui posé depuis un autre.
func TestPlaybackPreferencesPartialUpdateKeepsOtherFields(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})

	if rec := putPlaybackPreferences(user, `{"auto_skip_intro":true}`); rec.Code != http.StatusOK {
		t.Fatalf("put auto_skip_intro: status %d", rec.Code)
	}
	if rec := putPlaybackPreferences(user, `{"default_audio_lang":" FR "}`); rec.Code != http.StatusOK {
		t.Fatalf("put default_audio_lang: status %d", rec.Code)
	}

	prefs := getPlaybackPreferences(t, user)
	if !prefs.AutoSkipIntro || prefs.DefaultAudioLang != "fr" || prefs.UpdatedAt == "" {
		t.Fatalf("after two partial updates: got %+v", prefs)
	}

	if rec := putPlaybackPreferences(user, `{"default_audio_lang":""}`); rec.Code != http.StatusOK {
		t.Fatalf("clear default_audio_lang: status %d", rec.Code)
	}
	if prefs := getPlaybackPreferences(t, user); prefs.DefaultAudioLang != "" || !prefs.AutoSkipIntro {
		t.Fatalf("after clearing the language: got %+v", prefs)
	}
}

// Les réglages appartiennent à un compte : ceux d'un autre ne bougent pas.
func TestPlaybackPreferencesAreScopedToTheAccount(t *testing.T) {
	setupAuthDB(t)
	alice := createTestUser(t, "alice", false, models.Permissions{})
	bob := createTestUser(t, "bob", false, models.Permissions{})

	if rec := putPlaybackPreferences(alice, `{"auto_skip_intro":true,"default_audio_lang":"en"}`); rec.Code != http.StatusOK {
		t.Fatalf("put for alice: status %d", rec.Code)
	}
	if prefs := getPlaybackPreferences(t, bob); prefs.AutoSkipIntro || prefs.DefaultAudioLang != "" || prefs.UpdatedAt != "" {
		t.Fatalf("bob sees alice's preferences: %+v", prefs)
	}
}

func TestPlaybackPreferencesRejectInvalidInput(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})

	for _, body := range []string{
		`not json`,
		`{"default_audio_lang":"français"}`,
		`{"default_audio_lang":"f"}`,
		`{"default_audio_lang":"f1"}`,
		`{"still_watching_episodes":0}`,
		`{"still_watching_episodes":11}`,
		`{"still_watching_from":1320}`,
		`{"still_watching_from":1320,"still_watching_until":1440}`,
		`{"still_watching_from":600,"still_watching_until":600}`,
	} {
		if rec := putPlaybackPreferences(user, body); rec.Code != http.StatusBadRequest {
			t.Errorf("body %q: status %d, want 400", body, rec.Code)
		}
	}
	if prefs := getPlaybackPreferences(t, user); prefs.UpdatedAt != "" {
		t.Fatalf("a rejected update was stored: %+v", prefs)
	}
}

// Un compte qui n'a rien choisi n'est jamais interrogé : la question ne se
// pose que si on l'a allumée. Trois épisodes et toute la journée sont ce
// qu'elle propose à ce moment-là (ADR-0045).
func TestStillWatchingIsOffUntilAsked(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})

	prefs := getPlaybackPreferences(t, user)
	if prefs.StillWatchingEnabled || prefs.StillWatchingEpisodes != 3 ||
		prefs.StillWatchingFrom != models.StillWatchingAllDay ||
		prefs.StillWatchingUntil != models.StillWatchingAllDay {
		t.Fatalf("unsaved account: got %+v", prefs)
	}

	// Enregistrer un autre réglage ne doit pas allumer la question : la ligne
	// créée porte les mêmes défauts.
	if rec := putPlaybackPreferences(user, `{"auto_skip_intro":true}`); rec.Code != http.StatusOK {
		t.Fatalf("put auto_skip_intro: status %d", rec.Code)
	}
	prefs = getPlaybackPreferences(t, user)
	if prefs.StillWatchingEnabled || prefs.StillWatchingEpisodes != 3 ||
		prefs.StillWatchingFrom != models.StillWatchingAllDay {
		t.Fatalf("after an unrelated update: got %+v", prefs)
	}
}

// La plage horaire peut passer minuit, et se retire en remettant les deux
// bornes à -1.
func TestStillWatchingStoresAndClearsItsHours(t *testing.T) {
	setupAuthDB(t)
	user := createTestUser(t, "alice", false, models.Permissions{})

	body := `{"still_watching_enabled":true,"still_watching_episodes":2,` +
		`"still_watching_from":1320,"still_watching_until":360}`
	if rec := putPlaybackPreferences(user, body); rec.Code != http.StatusOK {
		t.Fatalf("put night hours: status %d", rec.Code)
	}
	prefs := getPlaybackPreferences(t, user)
	if prefs.StillWatchingEpisodes != 2 || prefs.StillWatchingFrom != 1320 || prefs.StillWatchingUntil != 360 {
		t.Fatalf("night hours: got %+v", prefs)
	}

	if rec := putPlaybackPreferences(user, `{"still_watching_enabled":false}`); rec.Code != http.StatusOK {
		t.Fatalf("disable: status %d", rec.Code)
	}
	if rec := putPlaybackPreferences(user, `{"still_watching_from":-1,"still_watching_until":-1}`); rec.Code != http.StatusOK {
		t.Fatalf("clear hours: status %d", rec.Code)
	}
	prefs = getPlaybackPreferences(t, user)
	if prefs.StillWatchingEnabled || prefs.StillWatchingEpisodes != 2 ||
		prefs.StillWatchingFrom != models.StillWatchingAllDay || prefs.StillWatchingUntil != models.StillWatchingAllDay {
		t.Fatalf("after disabling and clearing: got %+v", prefs)
	}
}
