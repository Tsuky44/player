package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Une requête de réglages tient en quelques dizaines d'octets.
const playbackPreferencesBodyLimit = 4 << 10

// playbackPreferencesUpdate est partiel : un champ absent garde sa valeur.
type playbackPreferencesUpdate struct {
	AutoSkipIntro    *bool   `json:"auto_skip_intro"`
	DefaultAudioLang *string `json:"default_audio_lang"`
}

var errInvalidAudioLang = errors.New("invalid audio language")

// normalizeAudioLang accepte un code de deux ou trois lettres, ou vide pour
// « la piste du fichier ». Le client envoie déjà un code normalisé ; le
// serveur refuse le reste plutôt que de ranger une chaîne qu'aucun appareil
// ne saura rapprocher d'une piste.
func normalizeAudioLang(raw string) (string, error) {
	lang := strings.ToLower(strings.TrimSpace(raw))
	if lang == "" {
		return "", nil
	}
	if len(lang) < 2 || len(lang) > 3 {
		return "", errInvalidAudioLang
	}
	for _, c := range lang {
		if c < 'a' || c > 'z' {
			return "", errInvalidAudioLang
		}
	}
	return lang, nil
}

// loadPlaybackPreferences renvoie les réglages du compte, ou les valeurs par
// défaut avec un UpdatedAt vide s'il n'a encore rien enregistré.
func loadPlaybackPreferences(userID int) (models.PlaybackPreferences, error) {
	var prefs models.PlaybackPreferences
	err := database.DB.QueryRow(`
		SELECT auto_skip_intro, default_audio_lang, updated_at
		FROM user_playback_preferences
		WHERE user_id = ?
	`, userID).Scan(&prefs.AutoSkipIntro, &prefs.DefaultAudioLang, &prefs.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return models.PlaybackPreferences{}, nil
	}
	if err != nil {
		return models.PlaybackPreferences{}, fmt.Errorf("load playback preferences: %w", err)
	}
	return prefs, nil
}

// applyPlaybackPreferencesUpdate fusionne une mise à jour partielle dans les
// réglages courants.
func applyPlaybackPreferencesUpdate(
	current models.PlaybackPreferences, update playbackPreferencesUpdate,
) (models.PlaybackPreferences, error) {
	if update.AutoSkipIntro != nil {
		current.AutoSkipIntro = *update.AutoSkipIntro
	}
	if update.DefaultAudioLang != nil {
		lang, err := normalizeAudioLang(*update.DefaultAudioLang)
		if err != nil {
			return models.PlaybackPreferences{}, err
		}
		current.DefaultAudioLang = lang
	}
	return current, nil
}

// GetPlaybackPreferences renvoie les réglages de lecture du compte
// (GET /api/me/playback-preferences).
func GetPlaybackPreferences(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	prefs, err := loadPlaybackPreferences(userID)
	if err != nil {
		log.Printf("GetPlaybackPreferences: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(prefs)
}

// UpdatePlaybackPreferences enregistre une mise à jour partielle et renvoie
// l'état stocké (PUT /api/me/playback-preferences).
func UpdatePlaybackPreferences(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, playbackPreferencesBodyLimit)
	var req playbackPreferencesUpdate
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	current, err := loadPlaybackPreferences(userID)
	if err != nil {
		log.Printf("UpdatePlaybackPreferences: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	next, err := applyPlaybackPreferencesUpdate(current, req)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid audio language")
		return
	}

	if _, err := database.DB.Exec(`
		INSERT INTO user_playback_preferences (user_id, auto_skip_intro, default_audio_lang, updated_at)
		VALUES (?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id) DO UPDATE SET
			auto_skip_intro = excluded.auto_skip_intro,
			default_audio_lang = excluded.default_audio_lang,
			updated_at = CURRENT_TIMESTAMP
	`, userID, next.AutoSkipIntro, next.DefaultAudioLang); err != nil {
		log.Printf("UpdatePlaybackPreferences: save: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}

	stored, err := loadPlaybackPreferences(userID)
	if err != nil {
		log.Printf("UpdatePlaybackPreferences: reload: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stored)
}
