package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Request statuses exposed to the client. They mirror MediaHub's vocabulary,
// plus "unavailable" for the case MediaHub itself could not be consulted.
const (
	requestStatusUnknown     = "unknown"     // absent everywhere → requestable
	requestStatusAvailable   = "available"   // already in the library
	requestStatusUnavailable = "unavailable" // MediaHub unreachable → no action offered
)

// showSeasonPayload is a season row as the library screen sees it. Missing
// seasons are TMDB-only and carry ID 0, which the client already treats as a
// virtual season.
type showSeasonPayload struct {
	models.Media
	IsAvailable   bool   `json:"is_available"`
	RequestStatus string `json:"request_status"`
	EpisodeCount  int    `json:"episode_count,omitempty"`
	CanRequest    bool   `json:"can_request"`
}

// seasonTitleNumber pulls a season number out of a folder-derived title such as
// "Saison 3", "Season 3" or "S03". Local rows often have season_number = 0.
var seasonTitleNumberRe = regexp.MustCompile(`(?i)^\s*(?:saison|season|s)\s*0*(\d+)\s*$`)

func seasonNumberFromTitle(title string) int {
	match := seasonTitleNumberRe.FindStringSubmatch(strings.TrimSpace(title))
	if len(match) < 2 {
		return 0
	}
	number, err := strconv.Atoi(match[1])
	if err != nil {
		return 0
	}
	return number
}

// GetShowSeasons returns every season of a show (GET /api/shows/:id/seasons):
// the ones held locally, plus the ones TMDB knows about but the server does not
// have, each carrying its MediaHub request status.
//
// TMDB and MediaHub are consulted on a short timeout with a cache in front. If
// either is unreachable the response degrades gracefully: seasons still list,
// but nothing is announced as requestable.
func GetShowSeasons(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	showID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid show ID"}`, http.StatusBadRequest)
		return
	}
	showID = indexer.ResolveCanonicalShowID(showID)

	local, err := loadLocalSeasons(showID)
	if err != nil {
		log.Printf("Seasons error: failed to query: %v", err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	seasons := mergeMissingSeasons(showID, local)
	_ = json.NewEncoder(w).Encode(seasons)
}

// loadLocalSeasons reads the seasons actually present in the database.
func loadLocalSeasons(showID int) ([]showSeasonPayload, error) {
	rows, err := database.DB.Query(`
		SELECT id, type, title, parent_id, COALESCE(season_number, 0),
		       COALESCE(poster_url, ''), COALESCE(overview, ''),
		       COALESCE(release_date, ''), created_at
		FROM medias
		WHERE type = 'season' AND parent_id = ?
		ORDER BY title ASC`, showID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	seasons := []showSeasonPayload{}
	for rows.Next() {
		var media models.Media
		var parentID, seasonNumber int
		var posterURL, overview, releaseDate string

		if err := rows.Scan(
			&media.ID, &media.Type, &media.Title, &parentID, &seasonNumber,
			&posterURL, &overview, &releaseDate, &media.CreatedAt,
		); err != nil {
			log.Printf("Seasons scan error: %v", err)
			continue
		}

		media.ParentID = &parentID
		media.PosterURL = posterURL
		media.Overview = overview
		media.ReleaseDate = releaseDate
		if seasonNumber <= 0 {
			seasonNumber = seasonNumberFromTitle(media.Title)
		}
		media.SeasonNumber = seasonNumber

		seasons = append(seasons, showSeasonPayload{
			Media:         media,
			IsAvailable:   true,
			RequestStatus: requestStatusAvailable,
			CanRequest:    false,
		})
	}
	return seasons, rows.Err()
}

// mergeMissingSeasons appends the TMDB seasons the library does not hold, and
// stamps each of them with its MediaHub status.
func mergeMissingSeasons(showID int, local []showSeasonPayload) []showSeasonPayload {
	tmdbID := showTMDBID(showID)
	tmdbSeasons := FetchTMDBShowSeasons(tmdbID)
	if len(tmdbSeasons) == 0 {
		// No TMDB match, or TMDB unreachable: local seasons only, unchanged
		// behaviour from before this endpoint was enriched.
		sortSeasons(local)
		return local
	}

	held := make(map[int]bool, len(local))
	for _, season := range local {
		if season.SeasonNumber > 0 {
			held[season.SeasonNumber] = true
		}
	}

	// A nil map means MediaHub could not be consulted, in which case nothing is
	// offered as requestable rather than guessing.
	statuses := mediaHubSeasonStatuses(tmdbID)

	seasons := local
	for _, tmdbSeason := range tmdbSeasons {
		if held[tmdbSeason.Number] {
			continue
		}

		status := requestStatusUnavailable
		if statuses != nil {
			status = requestStatusUnknown
			if known, ok := statuses[tmdbSeason.Number]; ok && known != "" {
				status = known
			}
		}

		title := tmdbSeason.Name
		if title == "" {
			title = "Saison " + strconv.Itoa(tmdbSeason.Number)
		}
		posterURL := ""
		if tmdbSeason.PosterPath != "" {
			posterURL = "https://image.tmdb.org/t/p/w500" + tmdbSeason.PosterPath
		}
		parentID := showID

		seasons = append(seasons, showSeasonPayload{
			Media: models.Media{
				ID:           0, // virtual season: no local row
				Type:         models.TypeSeason,
				Title:        title,
				ParentID:     &parentID,
				PosterURL:    posterURL,
				Overview:     tmdbSeason.Overview,
				ReleaseDate:  tmdbSeason.AirDate,
				SeasonNumber: tmdbSeason.Number,
				CreatedAt:    time.Time{},
			},
			IsAvailable:   false,
			RequestStatus: status,
			EpisodeCount:  tmdbSeason.EpisodeCount,
			CanRequest:    status == requestStatusUnknown,
		})
	}

	sortSeasons(seasons)
	return seasons
}

// sortSeasons orders by season number, keeping unnumbered local rows last so a
// badly named folder never hides the rest of the list.
func sortSeasons(seasons []showSeasonPayload) {
	sort.SliceStable(seasons, func(i, j int) bool {
		left, right := seasons[i].SeasonNumber, seasons[j].SeasonNumber
		if left <= 0 {
			return false
		}
		if right <= 0 {
			return true
		}
		return left < right
	})
}

// showTMDBID returns the show's TMDB id, or 0 when it was never matched.
func showTMDBID(showID int) int {
	var tmdbID sql.NullInt64
	err := database.DB.QueryRow(
		"SELECT tmdb_id FROM medias WHERE id = ? AND type = 'show'", showID,
	).Scan(&tmdbID)
	if err != nil || !tmdbID.Valid {
		return 0
	}
	return int(tmdbID.Int64)
}
