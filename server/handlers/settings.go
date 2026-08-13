package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"project-player/server/config"

	"github.com/julienschmidt/httprouter"
)

// GetSettings returns public server settings (GET /api/settings).
func GetSettings(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(config.Snapshot())
}

// UpdateSettings persists partial settings updates (PUT /api/settings).
func UpdateSettings(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	var req config.UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	snapshot, err := config.ApplyUpdate(req)
	if err != nil {
		log.Printf("UpdateSettings error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Failed to save settings")
		return
	}

	json.NewEncoder(w).Encode(snapshot)
}
