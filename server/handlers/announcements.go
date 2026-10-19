package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Le message de l'administrateur à tous les comptes du serveur (ADR-0069).
//
// Une seule annonce compte à la fois : la plus récente. Chaque compte retient
// la dernière qu'il a fermée, et c'est le serveur qui dit à l'app s'il y en a
// une à montrer — l'app n'a rien à comparer.

const (
	announcementBodyLimit  = 16 << 10
	maxAnnouncementTitle   = 120
	maxAnnouncementMessage = 4000
)

var errInvalidAnnouncement = errors.New("invalid announcement")

// announcementResponse porte l'annonce, ou null quand il n'y a rien à montrer.
type announcementResponse struct {
	Announcement *models.Announcement `json:"announcement"`
}

type announcementUpdate struct {
	Title   string `json:"title"`
	Message string `json:"message"`
}

type announcementSeenRequest struct {
	ID int `json:"id"`
}

// normalizeAnnouncement retire les blancs autour des deux champs et refuse un
// message vide ou trop long. Les longueurs se comptent en caractères : un
// message en français ne doit pas être coupé plus tôt pour ses accents.
func normalizeAnnouncement(req announcementUpdate) (announcementUpdate, error) {
	req.Title = strings.TrimSpace(req.Title)
	req.Message = strings.TrimSpace(req.Message)
	if req.Message == "" ||
		utf8.RuneCountInString(req.Title) > maxAnnouncementTitle ||
		utf8.RuneCountInString(req.Message) > maxAnnouncementMessage {
		return announcementUpdate{}, errInvalidAnnouncement
	}
	return req, nil
}

// loadCurrentAnnouncement renvoie l'annonce la plus récente, ou nil.
func loadCurrentAnnouncement() (*models.Announcement, error) {
	var a models.Announcement
	var created sql.NullString
	err := database.DB.QueryRow(`
		SELECT id, title, message, created_at
		FROM announcements
		ORDER BY id DESC
		LIMIT 1
	`).Scan(&a.ID, &a.Title, &a.Message, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load announcement: %w", err)
	}
	a.CreatedAt = scanSQLiteTime(created)
	return &a, nil
}

// loadPendingAnnouncement renvoie l'annonce courante si le compte ne l'a pas
// encore fermée.
func loadPendingAnnouncement(userID int) (*models.Announcement, error) {
	current, err := loadCurrentAnnouncement()
	if err != nil || current == nil {
		return nil, err
	}
	var seen int
	if err := database.DB.QueryRow(
		`SELECT seen_announcement_id FROM users WHERE id = ?`, userID,
	).Scan(&seen); err != nil {
		return nil, fmt.Errorf("load seen announcement: %w", err)
	}
	if seen >= current.ID {
		return nil, nil
	}
	return current, nil
}

// markAnnouncementSeen ne fait jamais reculer la marque : un appareil resté
// sur une ancienne annonce ne remontre pas la nouvelle à ceux qui l'ont lue.
func markAnnouncementSeen(userID, announcementID int) error {
	if _, err := database.DB.Exec(`
		UPDATE users SET seen_announcement_id = MAX(seen_announcement_id, ?)
		WHERE id = ?
	`, announcementID, userID); err != nil {
		return fmt.Errorf("mark announcement seen: %w", err)
	}
	return nil
}

// publishAnnouncement range une nouvelle annonce. Son auteur l'a déjà lue :
// elle ne s'affiche pas chez lui.
func publishAnnouncement(authorID int, req announcementUpdate) (*models.Announcement, error) {
	tx, err := database.DB.Begin()
	if err != nil {
		return nil, fmt.Errorf("publish announcement: begin: %w", err)
	}
	defer tx.Rollback()
	res, err := tx.Exec(`
		INSERT INTO announcements (title, message, author_id) VALUES (?, ?, ?)
	`, req.Title, req.Message, authorID)
	if err != nil {
		return nil, fmt.Errorf("publish announcement: insert: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, fmt.Errorf("publish announcement: id: %w", err)
	}
	// Les anciennes ne servent plus à rien : seule la dernière se lit.
	if _, err := tx.Exec(`DELETE FROM announcements WHERE id < ?`, id); err != nil {
		return nil, fmt.Errorf("publish announcement: prune: %w", err)
	}
	if _, err := tx.Exec(
		`UPDATE users SET seen_announcement_id = ? WHERE id = ?`, id, authorID,
	); err != nil {
		return nil, fmt.Errorf("publish announcement: author seen: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("publish announcement: commit: %w", err)
	}
	return loadCurrentAnnouncement()
}

func writeAnnouncement(w http.ResponseWriter, a *models.Announcement) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(announcementResponse{Announcement: a})
}

// GetPendingAnnouncement renvoie l'annonce que le compte n'a pas encore fermée,
// ou null (GET /api/me/announcement).
func GetPendingAnnouncement(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	pending, err := loadPendingAnnouncement(userID)
	if err != nil {
		log.Printf("GetPendingAnnouncement: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	writeAnnouncement(w, pending)
}

// MarkAnnouncementSeen note que le compte a fermé l'annonce
// (POST /api/me/announcement/seen).
func MarkAnnouncementSeen(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, announcementBodyLimit)
	var req announcementSeenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if err := markAnnouncementSeen(userID, req.ID); err != nil {
		log.Printf("MarkAnnouncementSeen: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(statusResponse{Status: "ok"})
}

// GetAnnouncement renvoie l'annonce en cours, lue ou non, pour l'éditeur des
// réglages (GET /api/announcement).
func GetAnnouncement(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	current, err := loadCurrentAnnouncement()
	if err != nil {
		log.Printf("GetAnnouncement: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	writeAnnouncement(w, current)
}

// PublishAnnouncement remplace l'annonce : tous les comptes la verront à leur
// prochaine ouverture de l'app, même ceux qui avaient fermé la précédente
// (PUT /api/announcement).
func PublishAnnouncement(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, announcementBodyLimit)
	var req announcementUpdate
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	req, err := normalizeAnnouncement(req)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, fmt.Sprintf(
			"Le message est vide ou trop long (titre %d, message %d caractères au plus)",
			maxAnnouncementTitle, maxAnnouncementMessage))
		return
	}
	published, err := publishAnnouncement(userID, req)
	if err != nil {
		log.Printf("PublishAnnouncement: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	writeAnnouncement(w, published)
}

// ClearAnnouncement retire l'annonce : plus personne ne la verra
// (DELETE /api/announcement).
func ClearAnnouncement(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	if _, err := database.DB.Exec(`DELETE FROM announcements`); err != nil {
		log.Printf("ClearAnnouncement: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	writeAnnouncement(w, nil)
}
