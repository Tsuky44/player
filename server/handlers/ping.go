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
	// GET /api/libraries existe, et /api/movies comme /api/shows acceptent
	// ?library= (ADR-0058).
	CapabilityLibraries = "libraries"
	// GET /api/me/announcement existe : le message de l'administrateur à tous
	// les comptes (ADR-0069).
	CapabilityAnnouncements = "announcements"
	// GET /api/media/:id/images/posters et PUT|DELETE /api/media/:id/poster
	// existent (ADR-0068).
	CapabilityPosterPicker = "poster_picker"
	// /api/lists existe : « à regarder plus tard » et les listes du compte,
	// partagées ou non (ADR-0070).
	CapabilityWatchLists = "watch_lists"
	// POST /api/settings/mediahub/test existe : le serveur vérifie lui-même
	// qu'il joint OnyxHub (ADR-0072).
	CapabilityMediaHubLinkTest = "mediahub_link_test"
	// GET /api/library/tmdb-index existe, et l'app web ouvre une fiche depuis
	// ?movie=ID ou ?show=ID (ADR-0073).
	CapabilityLibraryTMDBIndex = "library_tmdb_index"
	// GET /api/library/shows/:tmdb/episodes rend les épisodes lisibles d'une série par
	// identifiant TMDB (ADR-0082).
	CapabilityLibraryShowEpisodes = "library_show_episodes"
	// GET /api/requests/mine relaie les demandes du compte chez OnyxHub (ADR-0073).
	CapabilityMyRequests = "my_requests"
	// POST /api/integrations/onyxhub/imported avance l'indexation d'un import
	// annoncé par OnyxHub (ADR-0074).
	CapabilityOnyxHubImportSignal = "onyxhub_import_signal"
	// GET /api/requests/access et /api/requests/all, POST
	// /api/requests/moderation existent, et « mes demandes » vient en lots
	// avec leurs saisons, raisons et motifs de refus (ADR-0089).
	CapabilityMediaHubRequests = "mediahub_requests"
	// POST /api/integrations/mediahub/events reçoit les évènements signés de
	// MediaHub (ADR-0089).
	CapabilityMediaHubEvents = "mediahub_events"
	// PUT /api/me/avatar, POST /api/me/avatar/photo et
	// GET /api/users/:id/avatar existent : l'image de profil (ADR-0078).
	CapabilityAvatars = "avatars"
	// POST /api/integrations/mediahub/sso tire le code qui ouvre MediaHub
	// déjà connecté (ADR-0090).
	CapabilityMediaHubSSO = "mediahub_sso"
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
			CapabilityLibraries,
			CapabilityAnnouncements,
			CapabilityPosterPicker,
			CapabilityWatchLists,
			CapabilityMediaHubLinkTest,
			CapabilityLibraryTMDBIndex,
			CapabilityLibraryShowEpisodes,
			CapabilityMyRequests,
			CapabilityOnyxHubImportSignal,
			CapabilityAvatars,
			CapabilityMediaHubRequests,
			CapabilityMediaHubEvents,
			CapabilityMediaHubSSO,
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
