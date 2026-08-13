package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// virtualEpisodePayload is a TMDB-only episode, shaped like the episodes the
// library already serves so the client renders both from one list. ID 0 and
// is_available false mark it as not playable.
type virtualEpisodePayload struct {
	models.HomeMediaItem
	IsAvailable bool `json:"is_available"`
}

// GetShowSeasonEpisodes returns the TMDB episode list of a season the server
// does not hold (GET /api/shows/:id/seasons/:num/episodes).
//
// This is the missing-season counterpart of GetSeasonEpisodes, which keys off a
// local season row. Seasons the library does hold are not merged in here: a
// partially held season is served by GetSeasonEpisodes as before.
//
// Degrades to an empty list rather than an error when the show was never
// matched to TMDB or TMDB is unreachable — the screen then shows the season
// without its episodes instead of failing.
func GetShowSeasonEpisodes(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	showID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}
	seasonNumber, err := strconv.Atoi(ps.ByName("num"))
	if err != nil || seasonNumber <= 0 {
		http.Error(w, `{"error": "Invalid season number"}`, http.StatusBadRequest)
		return
	}
	showID = indexer.ResolveCanonicalShowID(showID)

	episodes := FetchTMDBSeasonEpisodes(showTMDBID(showID), seasonNumber)
	_ = json.NewEncoder(w).Encode(buildVirtualEpisodes(showID, seasonNumber, episodes))
}

// buildVirtualEpisodes maps TMDB episodes onto the library's episode shape.
func buildVirtualEpisodes(showID, seasonNumber int, episodes []TMDBEpisodeSummary) []virtualEpisodePayload {
	results := make([]virtualEpisodePayload, 0, len(episodes))
	for _, episode := range episodes {
		posterURL := ""
		if episode.StillPath != "" {
			posterURL = "https://image.tmdb.org/t/p/w500" + episode.StillPath
		}
		parentID := showID

		results = append(results, virtualEpisodePayload{
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
