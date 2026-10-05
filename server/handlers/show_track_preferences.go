package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// showTrackPreferencesUpdate est partiel : choisir un sous-titre ne remet pas
// la langue audio à zéro, et inversement.
type showTrackPreferencesUpdate struct {
	AudioLang *string                    `json:"audio_lang"`
	Subtitle  *models.ShowSubtitleChoice `json:"subtitle"`
}

var errInvalidSubtitleChoice = errors.New("invalid subtitle choice")

// Une clé de piste (`fr2`, `img3`) ou une langue de base : court, et rien qui
// ne sorte de ce que le catalogue de sous-titres produit lui-même.
const subtitleTokenMaxLen = 16

func normalizeSubtitleToken(raw string) (string, error) {
	token := strings.ToLower(strings.TrimSpace(raw))
	if len(token) > subtitleTokenMaxLen {
		return "", errInvalidSubtitleChoice
	}
	for _, c := range token {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' && c != '_' {
			return "", errInvalidSubtitleChoice
		}
	}
	return token, nil
}

// normalizeSubtitleChoice valide un choix de sous-titre. « Désactivés » ne
// garde aucune piste ; « activés » doit pouvoir en désigner une.
func normalizeSubtitleChoice(choice models.ShowSubtitleChoice) (models.ShowSubtitleChoice, error) {
	switch choice.Mode {
	case models.SubtitleModeOff:
		return models.ShowSubtitleChoice{Mode: models.SubtitleModeOff}, nil
	case models.SubtitleModeOn:
	default:
		return models.ShowSubtitleChoice{}, errInvalidSubtitleChoice
	}
	lang, err := normalizeSubtitleToken(choice.Lang)
	if err != nil {
		return models.ShowSubtitleChoice{}, err
	}
	key, err := normalizeSubtitleToken(choice.Key)
	if err != nil {
		return models.ShowSubtitleChoice{}, err
	}
	if lang == "" && key == "" {
		return models.ShowSubtitleChoice{}, errInvalidSubtitleChoice
	}
	choice.Lang = lang
	choice.Key = key
	return choice, nil
}

// showIDForTrackPreferences rattache un épisode à la série qui porte ses
// préférences. Deux lignes de la même série (doublon d'indexation) partagent
// la ligne canonique : sans cela, le choix fait en saison 1 ne vaudrait pas en
// saison 2.
func showIDForTrackPreferences(episodeID int) (int, bool) {
	showID, ok := resolveShowIDForEpisode(episodeID)
	if !ok {
		return 0, false
	}
	return indexer.ResolveCanonicalShowID(showID), true
}

// loadShowTrackPreferences renvoie les préférences du compte pour la série, ou
// des valeurs vides avec un UpdatedAt vide s'il n'y a encore rien choisi.
func loadShowTrackPreferences(userID, showID int) (models.ShowTrackPreferences, error) {
	prefs := models.ShowTrackPreferences{ShowID: showID}
	err := database.DB.QueryRow(`
		SELECT audio_lang, subtitle_mode, subtitle_lang, subtitle_key,
		       subtitle_forced, subtitle_image, updated_at
		FROM user_show_track_preferences
		WHERE user_id = ? AND show_id = ?
	`, userID, showID).Scan(
		&prefs.AudioLang, &prefs.Subtitle.Mode, &prefs.Subtitle.Lang, &prefs.Subtitle.Key,
		&prefs.Subtitle.Forced, &prefs.Subtitle.Image, &prefs.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return prefs, nil
	}
	if err != nil {
		return models.ShowTrackPreferences{}, fmt.Errorf("load show track preferences: %w", err)
	}
	return prefs, nil
}

func applyShowTrackPreferencesUpdate(
	current models.ShowTrackPreferences, update showTrackPreferencesUpdate,
) (models.ShowTrackPreferences, error) {
	if update.AudioLang != nil {
		lang, err := normalizeAudioLang(*update.AudioLang)
		if err != nil {
			return models.ShowTrackPreferences{}, err
		}
		current.AudioLang = lang
	}
	if update.Subtitle != nil {
		choice, err := normalizeSubtitleChoice(*update.Subtitle)
		if err != nil {
			return models.ShowTrackPreferences{}, err
		}
		current.Subtitle = choice
	}
	return current, nil
}

// episodeShowForTrackPreferences lit l'épisode de la route et répond lui-même
// quand il ne mène à aucune série.
func episodeShowForTrackPreferences(w http.ResponseWriter, ps httprouter.Params) (int, bool) {
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return 0, false
	}
	showID, ok := showIDForTrackPreferences(mediaID)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "Media is not an episode of a show")
		return 0, false
	}
	return showID, true
}

// GetShowTrackPreferences renvoie la langue audio et le sous-titre choisis
// pour la série de l'épisode (GET /api/episodes/:id/track-preferences).
//
// La route prend l'épisode et non la série : c'est le serveur qui sait à
// quelle série un épisode appartient, pas le lecteur qui l'ouvre.
func GetShowTrackPreferences(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	showID, ok := episodeShowForTrackPreferences(w, ps)
	if !ok {
		return
	}
	prefs, err := loadShowTrackPreferences(userID, showID)
	if err != nil {
		log.Printf("GetShowTrackPreferences: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(prefs)
}

// UpdateShowTrackPreferences enregistre une mise à jour partielle et renvoie
// l'état stocké (PUT /api/episodes/:id/track-preferences).
func UpdateShowTrackPreferences(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	showID, ok := episodeShowForTrackPreferences(w, ps)
	if !ok {
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, playbackPreferencesBodyLimit)
	var req showTrackPreferencesUpdate
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	current, err := loadShowTrackPreferences(userID, showID)
	if err != nil {
		log.Printf("UpdateShowTrackPreferences: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	next, err := applyShowTrackPreferencesUpdate(current, req)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid track preferences")
		return
	}

	if _, err := database.DB.Exec(`
		INSERT INTO user_show_track_preferences (
			user_id, show_id, audio_lang, subtitle_mode, subtitle_lang, subtitle_key,
			subtitle_forced, subtitle_image, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, show_id) DO UPDATE SET
			audio_lang = excluded.audio_lang,
			subtitle_mode = excluded.subtitle_mode,
			subtitle_lang = excluded.subtitle_lang,
			subtitle_key = excluded.subtitle_key,
			subtitle_forced = excluded.subtitle_forced,
			subtitle_image = excluded.subtitle_image,
			updated_at = CURRENT_TIMESTAMP
	`, userID, showID, next.AudioLang, next.Subtitle.Mode, next.Subtitle.Lang, next.Subtitle.Key,
		next.Subtitle.Forced, next.Subtitle.Image); err != nil {
		log.Printf("UpdateShowTrackPreferences: save: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}

	stored, err := loadShowTrackPreferences(userID, showID)
	if err != nil {
		log.Printf("UpdateShowTrackPreferences: reload: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stored)
}
