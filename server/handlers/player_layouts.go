package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// PlayerLayout represents a named Player Studio configuration owned by a user.
type PlayerLayout struct {
	ID          string          `json:"id"`
	Name        string          `json:"name"`
	Config      json.RawMessage `json:"config"`
	UseModular  bool            `json:"use_modular"`
	UpdatedAt   string          `json:"updated_at"`
}

type playerLayoutWriteRequest struct {
	Name       string          `json:"name"`
	Config     json.RawMessage `json:"config"`
	UseModular *bool           `json:"use_modular"`
}

func scanPlayerLayout(scanner interface {
	Scan(dest ...any) error
}) (PlayerLayout, error) {
	var layout PlayerLayout
	var config string
	var useModular int
	if err := scanner.Scan(
		&layout.ID,
		&layout.Name,
		&config,
		&useModular,
		&layout.UpdatedAt,
	); err != nil {
		return PlayerLayout{}, err
	}
	layout.Config = json.RawMessage(config)
	layout.UseModular = useModular != 0
	if layout.UpdatedAt == "" {
		layout.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	return layout, nil
}

func loadPlayerLayout(userID int, layoutID string) (PlayerLayout, error) {
	row := database.DB.QueryRow(`
		SELECT id, name, config_json, use_modular, updated_at
		FROM user_player_layouts
		WHERE user_id = ? AND id = ?
	`, userID, layoutID)
	return scanPlayerLayout(row)
}

func listPlayerLayouts(userID int) ([]PlayerLayout, error) {
	rows, err := database.DB.Query(`
		SELECT id, name, config_json, use_modular, updated_at
		FROM user_player_layouts
		WHERE user_id = ?
		ORDER BY updated_at DESC, name COLLATE NOCASE ASC
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	layouts := make([]PlayerLayout, 0)
	for rows.Next() {
		layout, err := scanPlayerLayout(rows)
		if err != nil {
			return nil, err
		}
		layouts = append(layouts, layout)
	}
	return layouts, rows.Err()
}

func normalizeLayoutName(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "Mon playeur"
	}
	if len(trimmed) > 64 {
		return trimmed[:64]
	}
	return trimmed
}

func validateLayoutConfig(raw json.RawMessage) (string, error) {
	if len(raw) == 0 {
		return "", errInvalidLayoutConfig
	}
	var probe any
	if err := json.Unmarshal(raw, &probe); err != nil {
		return "", errInvalidLayoutConfig
	}
	return string(raw), nil
}

var errInvalidLayoutConfig = &layoutValidationError{message: "Invalid layout config"}

type layoutValidationError struct {
	message string
}

func (e *layoutValidationError) Error() string { return e.message }

// ListPlayerLayouts returns every Player Studio layout for the authenticated user.
func ListPlayerLayouts(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	layouts, err := listPlayerLayouts(userID)
	if err != nil {
		log.Printf("player layouts list error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]any{
		"layouts": layouts,
	})
}

// CreatePlayerLayout creates a new named layout for the authenticated user.
func CreatePlayerLayout(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req playerLayoutWriteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	configJSON, err := validateLayoutConfig(req.Config)
	if err != nil {
		http.Error(w, `{"error": "Invalid layout config"}`, http.StatusBadRequest)
		return
	}

	id, err := GenerateRandomToken()
	if err != nil {
		log.Printf("player layout id error: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	useModular := false
	if req.UseModular != nil {
		useModular = *req.UseModular
	}
	name := normalizeLayoutName(req.Name)

	_, err = database.DB.Exec(`
		INSERT INTO user_player_layouts (id, user_id, name, config_json, use_modular, updated_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
	`, id, userID, name, configJSON, useModular)
	if err != nil {
		log.Printf("player layout create error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	layout, err := loadPlayerLayout(userID, id)
	if err != nil {
		log.Printf("player layout reload error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(layout)
}

// UpdatePlayerLayout updates an existing layout owned by the authenticated user.
func UpdatePlayerLayout(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	layoutID := strings.TrimSpace(ps.ByName("id"))
	if layoutID == "" {
		http.Error(w, `{"error": "Missing layout id"}`, http.StatusBadRequest)
		return
	}

	var req playerLayoutWriteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	existing, err := loadPlayerLayout(userID, layoutID)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Layout not found"}`, http.StatusNotFound)
			return
		}
		log.Printf("player layout load error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	name := existing.Name
	if req.Name != "" {
		name = normalizeLayoutName(req.Name)
	}

	configJSON := string(existing.Config)
	if len(req.Config) > 0 {
		configJSON, err = validateLayoutConfig(req.Config)
		if err != nil {
			http.Error(w, `{"error": "Invalid layout config"}`, http.StatusBadRequest)
			return
		}
	}

	useModular := existing.UseModular
	if req.UseModular != nil {
		useModular = *req.UseModular
	}

	_, err = database.DB.Exec(`
		UPDATE user_player_layouts
		SET name = ?, config_json = ?, use_modular = ?, updated_at = CURRENT_TIMESTAMP
		WHERE user_id = ? AND id = ?
	`, name, configJSON, useModular, userID, layoutID)
	if err != nil {
		log.Printf("player layout update error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	layout, err := loadPlayerLayout(userID, layoutID)
	if err != nil {
		log.Printf("player layout reload error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(layout)
}

// DeletePlayerLayout removes a layout owned by the authenticated user.
func DeletePlayerLayout(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	layoutID := strings.TrimSpace(ps.ByName("id"))
	if layoutID == "" {
		http.Error(w, `{"error": "Missing layout id"}`, http.StatusBadRequest)
		return
	}

	result, err := database.DB.Exec(`
		DELETE FROM user_player_layouts WHERE user_id = ? AND id = ?
	`, userID, layoutID)
	if err != nil {
		log.Printf("player layout delete error: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	affected, _ := result.RowsAffected()
	if affected == 0 {
		http.Error(w, `{"error": "Layout not found"}`, http.StatusNotFound)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{"status": "deleted"})
}
