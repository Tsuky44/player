package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"

	"project-player/server/config"
	"project-player/server/indexer"
	"project-player/server/mediahub"

	"github.com/julienschmidt/httprouter"
)

// Les évènements que MediaHub pousse vers Onyx (ADR-0087), à la place de
// l'import annoncé par OnyxHub (ADR-0074) : une demande a changé, ou Radarr
// et Sonarr viennent d'importer un fichier. Onyx oublie ce qu'il gardait en
// cache sur le titre, et indexe le fichier maintenant plutôt qu'au prochain
// passage du moniteur.

// maxEventSize : une demande sérialisée et sa centaine de chemins au plus.
const maxEventSize = 256 << 10

// MediaHubEvents reçoit un évènement (POST /api/integrations/mediahub/events).
// Sans compte : c'est MediaHub qui appelle, avec la clé d'intégration et la
// signature du corps.
func MediaHubEvents(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEventSize))
	if err != nil {
		writeJSONError(w, http.StatusRequestEntityTooLarge, "Évènement trop gros")
		return
	}
	if err := mediahub.VerifyDelivery(r.Header, body, config.MediaHubAPIKey()); err != nil {
		message := "Clé d'intégration invalide"
		if errors.Is(err, mediahub.ErrBadSignature) {
			message = "Signature invalide"
		}
		writeJSONError(w, http.StatusUnauthorized, message)
		return
	}
	event, err := mediahub.DecodeEvent(body)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	delivery := r.Header.Get("X-MediaHub-Delivery")
	if delivery == "" {
		delivery = event.ID
	}
	if mediahub.FirstDelivery(delivery) {
		if err := applyMediaHubEvent(event); err != nil {
			// Un 4xx : MediaHub ne réessaie pas un corps qu'Onyx ne lira pas mieux.
			writeJSONError(w, http.StatusBadRequest, "Invalid event data")
			return
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(statusResponse{Status: "accepted"})
}

// applyMediaHubEvent fait ce que l'évènement demande. Un évènement inconnu
// est accepté sans rien faire : une version plus récente de MediaHub peut en
// ajouter.
func applyMediaHubEvent(event mediahub.Event) error {
	switch event.Event {
	case mediahub.EventImported:
		var data mediahub.ImportedData
		if err := json.Unmarshal(event.Data, &data); err != nil || len(data.Paths) > mediahub.MaxImportPaths {
			return errors.New("bad media.imported data")
		}
		invalidateMediaHubStatus(data.TMDBID)
		// Les chemins sont ceux de Radarr et Sonarr : le moniteur ignore ceux
		// qui ne tombent dans aucune bibliothèque, et relève quand même les
		// dossiers surveillés.
		indexer.NudgeLibraryMonitor(data.Paths...)
	case mediahub.EventCreated, mediahub.EventStatusChanged, mediahub.EventDeleted:
		var data mediahub.RequestEventData
		if err := json.Unmarshal(event.Data, &data); err != nil {
			return errors.New("bad request event data")
		}
		invalidateMediaHubStatus(data.Request.TMDBID)
	case mediahub.EventTest:
		log.Printf("MediaHubEvents: évènement de test reçu (%s)", event.ID)
	}
	return nil
}
