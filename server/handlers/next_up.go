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
// when the server does not hold it and nobody has asked for it yet. The player
// turns this into its end-of-season card, so its mere presence is the offer:
// can_request only ever goes false client-side, once the request is sent and
// the card flips to confirming it.
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

// upcomingEpisodePayload describes the episode that comes after the last one the
// server holds, while its season is still running. It always takes precedence
// over nextSeasonPayload: a season airing week by week is not finished, so
// offering the season after it would skip over episodes still to come.
type upcomingEpisodePayload struct {
	ShowID         int    `json:"show_id"`
	ShowTitle      string `json:"show_title,omitempty"`
	SeasonNumber   int    `json:"season_number"`
	Number         int    `json:"number"`
	Name           string `json:"name,omitempty"`
	Overview       string `json:"overview,omitempty"`
	StillURL       string `json:"still_url,omitempty"`
	AirDate        string `json:"air_date,omitempty"`
	SeasonEpisodes int    `json:"season_episodes,omitempty"`
}

// GetNextEpisode answers "what comes after this episode?" (GET /api/episodes/:id/next).
//
// Four outcomes, in order:
//  1. another episode in the same season;
//  2. the first episode of the next season, when the library holds it;
//  3. no episode, but a description of the episode the season is still waiting
//     for, when its season has not finished airing;
//  4. no episode, but a description of the next season so the player can offer
//     to request it.
//
// Outcome 3 shadows outcome 4 wherever both could apply, including alongside
// outcome 2: while a season is still running, what follows its last held
// episode is that season's next episode, never the season after.
//
// Outcome 4 is omitted entirely when MediaHub cannot be consulted, the show has
// no TMDB match, or the season has already been requested: a card with a dead
// button is worse than no card.
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

	// The season this episode ends may simply not be over: computed once here
	// because every branch below has to defer to it.
	upcoming := describeUpcomingEpisode(showID, currentSeasonNum, currentEpisodeNum)

	// 2. First episode of the following season, when it is held locally.
	//
	// The following season is the lowest number above the current one across
	// local *and* TMDB seasons, so a gap is proposed for request rather than
	// silently skipped over to a later season that happens to be present.
	nextNumber, nextSeasonID := resolveFollowingSeason(showID, currentSeasonNum)
	if nextNumber == 0 {
		_ = json.NewEncoder(w).Encode(withUpcoming(
			map[string]interface{}{"has_next": false}, upcoming))
		return
	}
	if nextSeasonID > 0 {
		if item, ok := findEpisodeInSeason(userID, nextSeasonID, 0); ok {
			response := map[string]interface{}{
				"has_next": true,
				"episode":  item,
			}
			if upcoming != nil {
				// Playing on is still offered, but through the card, so
				// crossing a hole in the current season stays a deliberate act.
				response["upcoming_episode"] = upcoming
			} else if season := lookaheadMissingSeason(userID, item.ID); season != nil {
				response["next_season"] = season
			}
			_ = json.NewEncoder(w).Encode(response)
			return
		}
		// Season row exists but holds no episode: nothing to play, and nothing
		// to request either (MediaHub would report it as partial/available).
		_ = json.NewEncoder(w).Encode(withUpcoming(
			map[string]interface{}{"has_next": false}, upcoming))
		return
	}

	// 3/4. Nothing left to play: the season's next episode when it has one,
	// the missing season that follows otherwise.
	response := map[string]interface{}{"has_next": false}
	if upcoming != nil {
		response["upcoming_episode"] = upcoming
	} else if season := describeMissingSeason(showID, nextNumber); season != nil {
		response["next_season"] = season
	}
	_ = json.NewEncoder(w).Encode(response)
}

// withUpcoming attaches the upcoming episode to a response when there is one.
func withUpcoming(response map[string]interface{}, upcoming *upcomingEpisodePayload) map[string]interface{} {
	if upcoming != nil {
		response["upcoming_episode"] = upcoming
	}
	return response
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

	// A season still airing is not one to look past: its own next episode is
	// what follows, and there is nothing to download early for.
	if describeUpcomingEpisode(showID, seasonNumber, episodeNumber) != nil {
		return nil
	}

	number, localSeasonID := resolveFollowingSeason(showID, seasonNumber)
	if number == 0 || localSeasonID > 0 {
		return nil // no season after it, or the server already holds it
	}
	return describeMissingSeason(showID, number)
}

// describeUpcomingEpisode describes the episode TMDB lists right after
// afterEpisodeNumber in the same season, when the server does not hold it —
// a season airing week by week, or one imported only in part.
//
// Callers reach it only once the season has no local episode left to play, so
// any later episode TMDB knows about is by definition absent from the server.
// Returns nil when the season holds nothing more, which is what hands the
// screen back to the end-of-season card.
func describeUpcomingEpisode(showID, seasonNumber, afterEpisodeNumber int) *upcomingEpisodePayload {
	if afterEpisodeNumber <= 0 {
		// An unnumbered episode says nothing about its position in the season;
		// episode 1 would then read as "upcoming" for every one of them.
		return nil
	}

	episodes := FetchTMDBSeasonEpisodes(showTMDBID(showID), seasonNumber)
	if len(episodes) == 0 {
		return nil // TMDB unreachable or season unknown: claim nothing
	}

	next := nextTMDBEpisodeAfter(episodes, afterEpisodeNumber)
	if next == nil {
		return nil // the season is complete on the server
	}

	payload := &upcomingEpisodePayload{
		ShowID:         showID,
		ShowTitle:      showTitle(showID),
		SeasonNumber:   seasonNumber,
		Number:         next.Number,
		Name:           next.Name,
		Overview:       next.Overview,
		AirDate:        next.AirDate,
		SeasonEpisodes: len(episodes),
	}
	if next.StillPath != "" {
		payload.StillURL = "https://image.tmdb.org/t/p/w780" + next.StillPath
	}
	return payload
}

// nextTMDBEpisodeAfter returns the lowest-numbered episode above
// afterEpisodeNumber, or nil when the list ends there. TMDB order is not
// relied on: a season is scanned in full so a list out of order still yields
// the episode that actually comes next.
func nextTMDBEpisodeAfter(episodes []TMDBEpisodeSummary, afterEpisodeNumber int) *TMDBEpisodeSummary {
	var next *TMDBEpisodeSummary
	for i := range episodes {
		if episodes[i].Number <= afterEpisodeNumber {
			continue
		}
		if next == nil || episodes[i].Number < next.Number {
			next = &episodes[i]
		}
	}
	return next
}

// describeMissingSeason builds the end-of-season card payload, or nil when the
// card would have nothing to offer — MediaHub unreachable, or the season
// already asked for.
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
	if status != requestStatusUnknown {
		// Already requested, downloading, or sitting in MediaHub's library:
		// there is nothing left to ask for, so the card would interrupt the
		// credits only to state a fact the user already acted on.
		return nil
	}

	payload := &nextSeasonPayload{
		ShowID:        showID,
		ShowTMDBID:    tmdbID,
		ShowTitle:     showTitle(showID),
		Number:        seasonNumber,
		Name:          "Saison " + strconv.Itoa(seasonNumber),
		RequestStatus: status,
		CanRequest:    true,
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
	item, err := scanEpisodeItem(database.DB.QueryRow(`
		SELECT `+episodeItemColumns+`
		FROM medias m
		LEFT JOIN medias season ON m.parent_id = season.id AND season.type = 'season'
		LEFT JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.type = 'episode' AND m.parent_id = ?
		  AND COALESCE(m.episode_number, 0) > ?
		ORDER BY COALESCE(NULLIF(m.episode_number, 0), 9999), m.id ASC
		LIMIT 1`, userID, seasonID, afterEpisodeNumber))
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("NextEpisode error: %v", err)
		}
		return models.HomeMediaItem{}, false
	}

	return item, true
}
