package handlers

import (
	"encoding/json"
	"net/http"
)

// writeJSONError répond une erreur sous la seule forme que l'app sait lire :
// {"error": "…"}, avec un Content-Type JSON.
//
// Une centaine de routes passaient par http.Error avec un littéral JSON : le
// corps avait la bonne allure, mais l'en-tête disait text/plain. Dio ne
// décode alors pas la réponse, et l'app affichait « Une erreur est survenue »
// au lieu du message du serveur. Toutes les erreurs JSON passent par ici.
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
