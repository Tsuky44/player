package handlers

import (
	"encoding/json"
	"net/http"

	"project-player/server/buildinfo"

	"github.com/julienschmidt/httprouter"
)

// Les capacités que ce serveur annonce sur /api/ping.
//
// Une app ne sait pas quel serveur elle a en face : la médiathèque peut être
// servie par plusieurs, de versions différentes (ADR-0013). Jusqu'ici elle
// devinait — une route qui répond 404, une réponse rendue trop vite pour avoir
// été tenue. Chaque comportement que l'app doit pouvoir distinguer reçoit ici
// un nom, ajouté le jour où le serveur l'acquiert et jamais retiré ensuite.
const (
	// Les routes de lecture exigent un ticket (ADR-0038).
	CapabilityPlaybackTickets = "playback_tickets"
	// GET /api/progress/revision?since=… tient la requête jusqu'au changement.
	CapabilityProgressLongPoll = "progress_long_poll"
	// Les fiches suivent Accept-Language (ADR-0049).
	CapabilityMediaLanguage = "media_language"
	// Un épisode quitté dans son générique compte comme vu, décidé ici.
	CapabilityWatchedByCredits = "watched_by_credits"
)

type pingResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	// PlaybackTicketVersion précède les capacités : les apps déjà publiées
	// lisent cette clé pour savoir si la lecture exige un ticket. Elle reste.
	PlaybackTicketVersion int      `json:"playback_ticket_version"`
	Version               string   `json:"version"`
	Capabilities          []string `json:"capabilities"`
}

func pingPayload() pingResponse {
	return pingResponse{
		Status:                "ok",
		Message:               "Project Player Server is running",
		PlaybackTicketVersion: 1,
		Version:               buildinfo.Version,
		Capabilities: []string{
			CapabilityPlaybackTickets,
			CapabilityProgressLongPoll,
			CapabilityMediaLanguage,
			CapabilityWatchedByCredits,
		},
	}
}

// Ping dit que le serveur répond, quelle version il est et ce qu'il sait
// faire (GET /api/ping). Publique : c'est ce qu'une app interroge avant d'avoir
// un compte, et elle n'expose rien de la médiathèque.
func Ping(w http.ResponseWriter, _ *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(pingPayload())
}
