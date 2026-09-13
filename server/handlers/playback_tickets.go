package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
	"project-player/server/playbackauth"
)

var PlaybackTickets = playbackauth.NewStore()

// Authenticated accounts currently share the catalogue (ADR-0001). Profile
// restrictions will be applied here as well as on catalogue routes in phase 4.
func CreatePlaybackTicket(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var body struct {
		MediaID int `json:"media_id"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body) != nil || body.MediaID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media id")
		return
	}
	var found int
	if err := database.DB.QueryRow("SELECT id FROM medias WHERE id = ? AND type IN ('movie', 'episode') AND COALESCE(file_path, '') != ''", body.MediaID).Scan(&found); err != nil {
		writeJSONError(w, http.StatusNotFound, "Playable media not found")
		return
	}
	token, ticket, err := PlaybackTickets.Issue(userID, body.MediaID)
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "Playback ticket unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]interface{}{"ticket": token, "expires_at": ticket.ExpiresAt, "renew_after_seconds": 300})
}

// Secrets travel in the body, never in the management URL or access logs.
func UpdatePlaybackTicket(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var body struct {
		Ticket string `json:"ticket"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body) != nil || len(body.Ticket) != 43 {
		writeJSONError(w, http.StatusBadRequest, "Invalid ticket")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodDelete {
		PlaybackTickets.Revoke(body.Ticket, userID)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	ticket, err := PlaybackTickets.Renew(body.Ticket, userID)
	if err != nil {
		writeJSONError(w, http.StatusUnauthorized, "Playback ticket expired")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"expires_at": ticket.ExpiresAt})
}
