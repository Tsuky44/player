package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// progressRevision rend un jeton qui change dès que ce que le compte a regardé
// change : une position qui avance sur un autre appareil, un épisode coché vu,
// une entrée retirée de « Reprendre la lecture ».
//
// Il ne coûte rien à tenir : progress_changes reçoit déjà un numéro neuf à
// chaque écriture de progression, par déclencheur, quel que soit le handler.
// Le nombre de lignes accompagne le plus grand numéro parce qu'une suppression
// (fusion de doublons) ne fait monter aucun numéro.
func progressRevision(userID int) (string, error) {
	var seq, changes, hidden int
	var hiddenAt string
	err := database.DB.QueryRow(`
		SELECT
			(SELECT COALESCE(MAX(seq), 0) FROM progress_changes WHERE user_id = ?),
			(SELECT COUNT(*) FROM progress_changes WHERE user_id = ?),
			(SELECT COUNT(*) FROM continue_watching_hidden WHERE user_id = ?),
			(SELECT COALESCE(MAX(CAST(hidden_at AS TEXT)), '') FROM continue_watching_hidden WHERE user_id = ?)
	`, userID, userID, userID, userID).Scan(&seq, &changes, &hidden, &hiddenAt)
	if err != nil {
		return "", fmt.Errorf("read progress revision: %w", err)
	}
	return fmt.Sprintf("%d.%d.%d.%s", seq, changes, hidden, hiddenAt), nil
}

// GetProgressRevision répond au sondage des écrans ouverts
// (GET /api/progress/revision). L'accueil et les fiches le demandent toutes
// les quelques secondes et ne relisent leurs données que s'il a bougé : relire
// /api/home à ce rythme sur chaque appareil allumé coûterait bien plus cher
// que cette lecture d'index.
func GetProgressRevision(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	revision, err := progressRevision(userID)
	if err != nil {
		log.Printf("GetProgressRevision: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	json.NewEncoder(w).Encode(models.ProgressRevision{Revision: revision})
}
