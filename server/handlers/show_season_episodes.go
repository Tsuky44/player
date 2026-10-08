package handlers

import (
	"encoding/json"
	"net/http"
	"sort"
	"strconv"

	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// seasonEpisodePayload is one episode of a season as the show page lists it:
// either a library row, or a TMDB-only episode carrying ID 0 and is_available
// false, which the client renders as not playable.
type seasonEpisodePayload struct {
	models.HomeMediaItem
	IsAvailable bool `json:"is_available"`
}

// GetShowSeasonEpisodes returns the TMDB episode list of a season the server
// does not hold (GET /api/shows/:id/seasons/:num/episodes).
//
// This is the missing-season counterpart of GetSeasonEpisodes, which keys off a
// local season row and merges the episodes it lacks on request (?missing=1).
//
// Degrades to an empty list rather than an error when the show was never
// matched to TMDB or TMDB is unreachable — the screen then shows the season
// without its episodes instead of failing.
func GetShowSeasonEpisodes(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	showID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid show ID")
		return
	}
	seasonNumber, err := strconv.Atoi(ps.ByName("num"))
	if err != nil || seasonNumber <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid season number")
		return
	}
	showID = indexer.ResolveCanonicalShowID(showID)

	episodes := FetchTMDBSeasonEpisodes(showTMDBID(showID), seasonNumber, languageOf(r))
	_ = json.NewEncoder(w).Encode(buildVirtualEpisodes(showID, seasonNumber, episodes))
}

// buildVirtualEpisodes maps TMDB episodes onto the library's episode shape.
func buildVirtualEpisodes(showID, seasonNumber int, episodes []TMDBEpisodeSummary) []seasonEpisodePayload {
	results := make([]seasonEpisodePayload, 0, len(episodes))
	for _, episode := range episodes {
		posterURL := ""
		if episode.StillPath != "" {
			posterURL = "https://image.tmdb.org/t/p/w500" + episode.StillPath
		}
		parentID := showID

		results = append(results, seasonEpisodePayload{
			HomeMediaItem: models.HomeMediaItem{
				Media: models.Media{
					ID:            0, // no local row: nothing to play
					Type:          models.TypeEpisode,
					Title:         episode.Name,
					ParentID:      &parentID,
					PosterURL:     posterURL,
					Overview:      episode.Overview,
					ReleaseDate:   episode.AirDate,
					SeasonNumber:  seasonNumber,
					EpisodeNumber: episode.Number,
				},
				Duration: episode.Runtime * 60, // TMDB reports minutes
			},
			IsAvailable: false,
		})
	}
	return results
}

// withMissingEpisodes complète les épisodes d'une saison présente par ceux que
// TMDB annonce et que le serveur n'a pas : une série en cours de diffusion
// montre ainsi ses prochains épisodes, avec leur date, au lieu de s'arrêter au
// dernier fichier reçu.
//
// Dégrade vers la liste locale seule quand la série n'est pas rattachée à TMDB
// ou que TMDB ne répond pas.
func withMissingEpisodes(seasonID int, local []models.HomeMediaItem, lang mediaLanguage) []seasonEpisodePayload {
	showID, seasonNumber := seasonPosition(seasonID)
	if showID <= 0 || seasonNumber <= 0 {
		return mergeMissingEpisodes(local, nil)
	}
	tmdb := FetchTMDBSeasonEpisodes(showTMDBID(showID), seasonNumber, lang)
	return mergeMissingEpisodes(local, buildVirtualEpisodes(showID, seasonNumber, tmdb))
}

// mergeMissingEpisodes ajoute aux épisodes locaux les épisodes virtuels dont le
// numéro n'est pas déjà tenu, puis range le tout par numéro.
//
// Un épisode local sans numéro peut être n'importe lequel de la saison : plutôt
// que d'annoncer « manquant » un épisode peut-être présent, rien n'est ajouté.
func mergeMissingEpisodes(local []models.HomeMediaItem, virtual []seasonEpisodePayload) []seasonEpisodePayload {
	results := make([]seasonEpisodePayload, 0, len(local)+len(virtual))
	held := make(map[int]bool, len(local))
	allNumbered := true
	for _, item := range local {
		if item.EpisodeNumber > 0 {
			held[item.EpisodeNumber] = true
		} else {
			allNumbered = false
		}
		results = append(results, seasonEpisodePayload{
			HomeMediaItem: item,
			IsAvailable:   item.ID > 0 && item.FilePath != "",
		})
	}
	if !allNumbered {
		return results
	}

	for _, episode := range virtual {
		if episode.EpisodeNumber <= 0 || held[episode.EpisodeNumber] {
			continue
		}
		results = append(results, episode)
	}
	sort.SliceStable(results, func(i, j int) bool {
		return results[i].EpisodeNumber < results[j].EpisodeNumber
	})
	return results
}
