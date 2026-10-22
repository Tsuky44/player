package handlers

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"image"
	_ "image/jpeg" // décodeurs enregistrés pour image.DecodeConfig
	_ "image/png"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// L'image de profil d'un compte (ADR-0078). Le serveur ne connaît pas la
// galerie : une clé de préréglage est opaque pour lui, c'est l'app qui la
// dessine. Il garde en revanche les photos, pour qu'elles suivent le compte
// sur tous ses appareils.

const (
	// L'app recadre et réduit la photo avant l'envoi (384 px de côté, en PNG,
	// soit 600 Ko au pire) : un mégaoctet laisse de la marge sans faire de la
	// base un dépôt de photos.
	maxAvatarPhotoBytes = 1 << 20
	maxAvatarPhotoSide  = 2048
	avatarPresetPrefix  = "preset:"
	avatarPhotoPrefix   = "photo:"
)

// avatarPresetKey borne ce qu'une clé de galerie peut être : elle est rendue
// telle quelle à toutes les apps, elle n'a pas à porter autre chose qu'un nom.
var avatarPresetKey = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)

// SetAvatarRequest est le corps de PUT /api/me/avatar. Une clé vide revient à
// l'initiale.
type SetAvatarRequest struct {
	Preset string `json:"preset"`
}

// SetMyAvatar choisit un avatar de la galerie, ou revient à l'initiale. La
// photo envoyée auparavant est effacée : elle n'est plus affichée nulle part.
func SetMyAvatar(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req SetAvatarRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	avatar := ""
	if req.Preset != "" {
		if !avatarPresetKey.MatchString(req.Preset) {
			writeJSONError(w, http.StatusBadRequest, "Avatar inconnu")
			return
		}
		avatar = avatarPresetPrefix + req.Preset
	}
	if err := storeAvatar(userID, avatar, nil, ""); err != nil {
		log.Printf("SetMyAvatar: store: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	writeUser(w, userID)
}

// UploadMyAvatarPhoto reçoit la photo de profil, octets bruts dans le corps,
// JPEG ou PNG. Le contenu est décodé avant d'être gardé : un fichier qui se dit
// image sans en être une ne finira pas servi aux autres comptes.
func UploadMyAvatarPhoto(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAvatarPhotoBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSONError(w, http.StatusRequestEntityTooLarge, "Photo trop lourde (1 Mo au plus)")
		return
	}
	contentType, err := validateAvatarPhoto(data)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	version := strconv.FormatInt(time.Now().UnixMilli(), 10)
	if err := storeAvatar(userID, avatarPhotoPrefix+version, data, contentType); err != nil {
		log.Printf("UploadMyAvatarPhoto: store: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	writeUser(w, userID)
}

// GetUserAvatar sert la photo d'un compte du serveur. Il faut une session :
// une photo de quelqu'un n'est pas un fichier public, mais les autres comptes
// du serveur la voient (séance commune, « Qui regarde ? » d'un appareil
// partagé). L'URL porte la version, d'où un cache long.
func GetUserAvatar(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, _ int) {
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid user id")
		return
	}
	var contentType string
	var photo []byte
	err = database.DB.QueryRow(
		`SELECT content_type, image FROM user_avatar_photos WHERE user_id = ?`, id,
	).Scan(&contentType, &photo)
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusNotFound, "No photo")
		return
	}
	if err != nil {
		log.Printf("GetUserAvatar: query: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	_, _ = w.Write(photo)
}

// validateAvatarPhoto rend le type de l'image, ou l'erreur à montrer.
func validateAvatarPhoto(data []byte) (string, error) {
	if len(data) == 0 {
		return "", fmt.Errorf("Photo vide")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return "", fmt.Errorf("Ce fichier n'est pas une image JPEG ou PNG")
	}
	if config.Width > maxAvatarPhotoSide || config.Height > maxAvatarPhotoSide {
		return "", fmt.Errorf("Photo trop grande (%d px de côté au plus)", maxAvatarPhotoSide)
	}
	switch format {
	case "jpeg":
		return "image/jpeg", nil
	case "png":
		return "image/png", nil
	}
	return "", fmt.Errorf("Ce fichier n'est pas une image JPEG ou PNG")
}

// storeAvatar écrit le choix et la photo ensemble : un compte qui annonce une
// photo sans l'avoir, ou l'inverse, afficherait une image cassée.
func storeAvatar(userID int, avatar string, photo []byte, contentType string) error {
	tx, err := database.DB.Begin()
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`UPDATE users SET avatar = ? WHERE id = ?`, avatar, userID); err != nil {
		return fmt.Errorf("update user: %w", err)
	}
	if photo == nil {
		if _, err := tx.Exec(`DELETE FROM user_avatar_photos WHERE user_id = ?`, userID); err != nil {
			return fmt.Errorf("delete photo: %w", err)
		}
	} else if _, err := tx.Exec(
		`INSERT INTO user_avatar_photos (user_id, content_type, image, updated_at)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(user_id) DO UPDATE SET
		   content_type = excluded.content_type,
		   image = excluded.image,
		   updated_at = excluded.updated_at`,
		userID, contentType, photo, time.Now().UnixMilli(),
	); err != nil {
		return fmt.Errorf("store photo: %w", err)
	}
	return tx.Commit()
}

// writeUser rend le compte tel que /api/auth/me le rendrait : l'app remplace
// son profil en cache par la réponse.
func writeUser(w http.ResponseWriter, userID int) {
	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("avatars: load user: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(user)
}
