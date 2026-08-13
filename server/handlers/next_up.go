package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// nextSeasonPayload describes the season that follows the one just finished,
// when the server does not hold it. The player turns this into its end-of-season
// card; can_request drives whether that card offers an action at all.
type nextSeasonPayload struct {
	ShowID        int    `json:"show_id"`
	ShowTMDBID    int    `json:"show_tmdb_id"`
	ShowTitle     string `json:"show_title,omitempty"`
	Number        int    `json:"number"`
	Name          string `json:"name"`
	Overview      string `json:"overview,omitempty"`
	PosterURL     string `json:"poster_url,omitempty"`
	EpisodeCount  int    `json:"episode_count,omitempty"`
	RequestStatus string `json:"request_status"`
	CanRequest    bool   `json:"can_request"`
}

// GetNextEpisode answers "what comes after this episode?" (GET /api/episodes/:id/next).
//
// Three outcomes, in order:
//  1. another episode in the same season;
//  2. the first episode of the next season, when the library holds it;
//  3. no episode, but a description of the next season so the player can offer
//     to request it.
//
// Outcome 3 is omitted entirely when MediaHub cannot be consulted or the show
// has no TMDB match: a card with a dead button is worse than no card.
func GetNextEpisode(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	episodeID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid episode ID"}`, http.StatusBadRequest)
		return
	}

	seasonID, currentEpisodeNum, err := currentEpisodePosition(episodeID)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Episode not found"}`, http.StatusNotFound)
		} else {
			log.Printf("NextEpisode error: %v", err)
			http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		}
		return
	}

	// 1. Next episode within the same season.
	if item, ok := findEpisodeInSeason(userID, seasonID, currentEpisodeNum); ok {
		response := map[string]interface{}{
			"has_next": true,
			"episode":  item,
		}
		if season := lookaheadMissingSeason(userID, item.ID); season != nil {
			response["next_season"] = season
		}
		_ = json.NewEncoder(w).Encode(response)
		return
	}

	showID, currentSeasonNum := seasonPosition(seasonID)
	if showID == 0 || currentSeasonNum <= 0 {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"has_next": false})
		return
	}

	// 2. First episode of the following season, when it is held locally.
	//
	// The following season is the lowest number above the current one across
	// local *and* TMDB seasons, so a gap is proposed for request rather than
	// silently skipped over to a later season that happens to be present.
	nextNumber, nextSeasonID := resolveFollowingSeason(showID, currentSeasonNum)
	if nextNumber == 0 {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"has_next": false})
		return
	}
	if nextSeasonID > 0 {
		if item, ok := findEpisodeInSeason(userID, nextSeasonID, 0); ok {
			response := map[string]interface{}{
				"has_next": true,
				"episode":  item,
			}
			if season := lookaheadMissingSeason(userID, item.ID); season != nil {
				response["next_season"] = season
			}
			_ = json.NewEncoder(w).Encode(response)
			return
		}
		// Season row exists but holds no episode: nothing to play, and nothing
		// to request either (MediaHub would report it as partial/available).
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"has_next": false})
		return
	}

	// 3. The following season is missing from the server.
	response := map[string]interface{}{"has_next": false}
	if season := describeMissingSeason(showID, nextNumber); season != nil {
		response["next_season"] = season
	}
	_ = json.NewEncoder(w).Encode(response)
}

// currentEpisodePosition returns the season row and episode number of an episode.
func currentEpisodePosition(episodeID int) (seasonID, episodeNumber int, err error) {
	err = database.DB.QueryRow(
		"SELECT parent_id, COALESCE(episode_number, 0) FROM medias WHERE id = ? AND type = 'episode'",
		episodeID,
	).Scan(&seasonID, &episodeNumber)
	return seasonID, episodeNumber, err
}

// seasonPosition returns the show a season belongs to and its season number,
// falling back to the title when the column was never filled.
func seasonPosition(seasonID int) (showID, seasonNumber int) {
	var parentID int
	var number int
	var title string
	err := database.DB.QueryRow(`
		SELECT parent_id, COALESCE(season_number, 0), title
		FROM medias WHERE id = ? AND type = 'season'`, seasonID,
	).Scan(&parentID, &number, &title)
	if err != nil {
		return 0, 0
	}
	if number <= 0 {
		number = seasonNumberFromTitle(title)
	}
	// Duplicate show rows are merged behind a canonical id; season lookups must
	// use the same id as GetShowSeasons or the seasons would not line up.
	return indexer.ResolveCanonicalShowID(parentID), number
}

// resolveFollowingSeason returns the number of the season that follows
// currentNumber, and its local row id (0 when the server does not hold it).
func resolveFollowingSeason(showID, currentNumber int) (number, localSeasonID int) {
	local, err := loadLocalSeasons(showID)
	if err != nil {
		log.Printf("NextEpisode: failed to load seasons of show %d: %v", showID, err)
		local = nil
	}

	best, bestID := 0, 0
	for _, season := range local {
		if season.SeasonNumber > currentNumber && (best == 0 || season.SeasonNumber < best) {
			best, bestID = season.SeasonNumber, season.ID
		}
	}
	for _, season := range FetchTMDBShowSeasons(showTMDBID(showID)) {
		if season.Number > currentNumber && (best == 0 || season.Number < best) {
			best, bestID = season.Number, 0
		}
	}
	return best, bestID
}

// lookaheadMissingSeason describes the season that will follow once nextEpisodeID
// — the episode the player is about to be offered — is over, but only when that
// episode is the last one the server holds.
//
// It lets the player raise the request card one episode early, so the download
// and the import can run while that final episode plays instead of after it.
// Returns nil whenever the offer would be premature or actionless.
func lookaheadMissingSeason(userID, nextEpisodeID int) *nextSeasonPayload {
	seasonID, episodeNumber, err := currentEpisodePosition(nextEpisodeID)
	if err != nil {
		return nil
	}
	if _, ok := findEpisodeInSeason(userID, seasonID, episodeNumber); ok {
		return nil // more episodes after it: nothing to look ahead to yet
	}

	showID, seasonNumber := seasonPosition(seasonID)
	if showID == 0 || seasonNumber <= 0 {
		return nil
	}

	number, localSeasonID := resolveFollowingSeason(showID, seasonNumber)
	if number == 0 || localSeasonID > 0 {
		return nil // no season after it, or the server already holds it
	}
	return describeMissingSeason(showID, number)
}

// describeMissingSeason builds the end-of-season card payload, or nil when no
// action can be offered for it.
func describeMissingSeason(showID, seasonNumber int) *nextSeasonPayload {
	tmdbID := showTMDBID(showID)
	statuses := mediaHubSeasonStatuses(tmdbID)
	if statuses == nil {
		return nil // MediaHub unreachable or show unmatched: show no card at all
	}

	status := requestStatusUnknown
	if known, ok := statuses[seasonNumber]; ok && known != "" {
		status = known
	}

	payload := &nextSeasonPayload{
		ShowID:        showID,
		ShowTMDBID:    tmdbID,
		ShowTitle:     showTitle(showID),
		Number:        seasonNumber,
		Name:          "Saison " + strconv.Itoa(seasonNumber),
		RequestStatus: status,
		CanRequest:    status == requestStatusUnknown,
	}

	for _, season := range FetchTMDBShowSeasons(tmdbID) {
		if season.Number != seasonNumber {
			continue
		}
		if season.Name != "" {
			payload.Name = season.Name
		}
		payload.Overview = season.Overview
		payload.EpisodeCount = season.EpisodeCount
		if season.PosterPath != "" {
			payload.PosterURL = "https://image.tmdb.org/t/p/w500" + season.PosterPath
		}
		break
	}
	return payload
}

func showTitle(showID int) string {
	var title string
	if err := database.DB.QueryRow(
		"SELECT title FROM medias WHERE id = ? AND type = 'show'", showID,
	).Scan(&title); err != nil {
		return ""
	}
	return title
}

// findEpisodeInSeason returns the first episode of a season whose number is
// above afterEpisodeNumber. Pass 0 to get the season's first episode.
func findEpisodeInSeason(userID, seasonID, afterEpisodeNumber int) (models.HomeMediaItem, bool) {
	query := `
		SELECT m.id, m.type, m.title, m.file_path, m.duration, m.parent_id, m.poster_url, m.overview, m.release_date, m.tmdb_id, m.created_at,
		       COALESCE(p.current_position_seconds, 0) as current_position,
		       COALESCE(p.is_finished, 0) as is_finished,
		       m.intro_start, m.intro_end, m.outro_start, m.outro_end,
		       COALESCE(NULLIF(m.season_number, 0), season.season_number, 0),
		       COALESCE(m.episode_number, 0),
		       COALESCE(season.title, ''),
		       COALESCE(show_m.title, '')
		FROM medias m
		LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		  AND COALESCE(m.episode_number, 0) > ?
		ORDER BY COALESCE(NULLIF(m.episode_number, 0), 9999), m.id ASC
		LIMIT 1
	`

	var item models.HomeMediaItem
	var filePath, posterURL, overview, releaseDate, showTitleRow sql.NullString
	var tmdbID sql.NullInt64
	var parentID, seasonNumber, episodeNumber int
	var seasonTitle string

	err := database.DB.QueryRow(query, userID, seasonID, afterEpisodeNumber).Scan(
		&item.ID, &item.Type, &item.Title, &filePath, &item.Duration, &parentID, &posterURL, &overview, &releaseDate, &tmdbID, &item.CreatedAt,
		&item.CurrentPositionSeconds, &item.IsFinished,
		&item.IntroStart, &item.IntroEnd, &item.OutroStart, &item.OutroEnd,
		&seasonNumber, &episodeNumber, &seasonTitle, &showTitleRow,
	)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("NextEpisode error: %v", err)
		}
		return models.HomeMediaItem{}, false
	}

	item.ParentID = &parentID
	if filePath.Valid {
		item.FilePath = filePath.String
	}
	if posterURL.Valid {
		item.PosterURL = posterURL.String
	}
	if overview.Valid {
		item.Overview = overview.String
	}
	if releaseDate.Valid {
		item.ReleaseDate = releaseDate.String
	}
	if tmdbID.Valid {
		item.TMDBID = int(tmdbID.Int64)
	}
	item.SeasonNumber = resolveSeasonNumber(seasonTitle, item.FilePath, seasonNumber)
	item.EpisodeNumber = parseEpisodeNumber(item.Title, episodeNumber)
	if showTitleRow.Valid && showTitleRow.String != "" {
		item.ShowTitle = showTitleRow.String
	}

	return item, true
}
