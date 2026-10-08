package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project-player/server/config"
	"project-player/server/httpx"
	"project-player/server/tmdb"
	"project-player/server/ttlcache"
)

// Shared TMDB/MediaHub lookups used by both the requests catalog and the
// library. Season lists and season episodes barely ever change, so they are
// cached for a long while; MediaHub statuses change as soon as a download
// starts, so they get a short TTL.
const (
	tmdbSeasonsCacheTTL    = 30 * time.Minute
	tmdbEpisodesCacheTTL   = 30 * time.Minute
	mediaHubStatusCacheTTL = 30 * time.Second
)

// tmdbFastClient serves the library detail screen, which used to be a single
// SQLite read. A short timeout keeps a slow TMDB from stalling that screen: the
// caller falls back to local-only seasons instead.
var tmdbFastClient = httpx.Fast

// tmdbCacheMaxEntries plafonne chacun des caches ci-dessous. Leurs clés
// portent la langue de la requête et, pour le catalogue des demandes, des
// séries que la médiathèque n'a pas : leur nombre n'est pas borné par elle.
const tmdbCacheMaxEntries = 512

// TMDBSeasonSummary is one season as TMDB describes it, independent of what the
// library actually holds.
type TMDBSeasonSummary struct {
	Number       int
	Name         string
	Overview     string
	EpisodeCount int
	PosterPath   string
	AirDate      string
}

// TMDBEpisodeSummary is one episode as TMDB describes it.
type TMDBEpisodeSummary struct {
	Number    int
	Name      string
	Overview  string
	StillPath string
	AirDate   string
	Runtime   int
	Rating    float64
}

var (
	tmdbSeasonsCache    = ttlcache.New[[]TMDBSeasonSummary](tmdbSeasonsCacheTTL, tmdbCacheMaxEntries)
	tmdbEpisodesCache   = ttlcache.New[[]TMDBEpisodeSummary](tmdbEpisodesCacheTTL, tmdbCacheMaxEntries)
	mediaHubStatusCache = ttlcache.New[map[int]string](mediaHubStatusCacheTTL, tmdbCacheMaxEntries)
)

// FetchTMDBShowSeasons returns every season TMDB knows for a show, specials
// (season 0) excluded, named in lang. Returns nil when TMDB is unreachable or
// unconfigured.
func FetchTMDBShowSeasons(tmdbID int, lang mediaLanguage) []TMDBSeasonSummary {
	if tmdbID <= 0 {
		return nil
	}
	key := strconv.Itoa(tmdbID) + "/" + lang.code
	if cached, ok := tmdbSeasonsCache.Get(key); ok {
		return cached
	}

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		return nil
	}
	target := fmt.Sprintf(
		"/tv/%d?language=%s",
		tmdbID, lang.tmdbLocale(),
	)
	resp, err := tmdb.Get(tmdbFastClient, target)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var payload struct {
		Seasons []struct {
			SeasonNumber int     `json:"season_number"`
			Name         string  `json:"name"`
			Overview     string  `json:"overview"`
			EpisodeCount int     `json:"episode_count"`
			PosterPath   *string `json:"poster_path"`
			AirDate      string  `json:"air_date"`
		} `json:"seasons"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil
	}

	seasons := make([]TMDBSeasonSummary, 0, len(payload.Seasons))
	for _, s := range payload.Seasons {
		if s.SeasonNumber <= 0 {
			continue // specials are never listed nor requestable
		}
		poster := ""
		if s.PosterPath != nil {
			poster = *s.PosterPath
		}
		seasons = append(seasons, TMDBSeasonSummary{
			Number:       s.SeasonNumber,
			Name:         strings.TrimSpace(s.Name),
			Overview:     s.Overview,
			EpisodeCount: s.EpisodeCount,
			PosterPath:   poster,
			AirDate:      s.AirDate,
		})
	}
	tmdbSeasonsCache.Put(key, seasons)
	return seasons
}

// FetchTMDBSeasonEpisodes returns the episodes TMDB lists for one season, in
// lang. Returns nil when TMDB is unreachable or the season does not exist.
func FetchTMDBSeasonEpisodes(tmdbID, seasonNumber int, lang mediaLanguage) []TMDBEpisodeSummary {
	if tmdbID <= 0 || seasonNumber < 0 {
		return nil
	}
	key := fmt.Sprintf("%d/%d/%s", tmdbID, seasonNumber, lang.code)
	if cached, ok := tmdbEpisodesCache.Get(key); ok {
		return cached
	}

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		return nil
	}
	target := fmt.Sprintf(
		"/tv/%d/season/%d?language=%s",
		tmdbID, seasonNumber, lang.tmdbLocale(),
	)
	resp, err := tmdb.Get(tmdbFastClient, target)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var payload struct {
		Episodes []struct {
			Name          string  `json:"name"`
			Overview      string  `json:"overview"`
			StillPath     *string `json:"still_path"`
			EpisodeNumber int     `json:"episode_number"`
			AirDate       string  `json:"air_date"`
			VoteAverage   float64 `json:"vote_average"`
			Runtime       *int    `json:"runtime"`
		} `json:"episodes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil
	}

	episodes := make([]TMDBEpisodeSummary, 0, len(payload.Episodes))
	for _, ep := range payload.Episodes {
		still := ""
		if ep.StillPath != nil {
			still = *ep.StillPath
		}
		runtime := 0
		if ep.Runtime != nil {
			runtime = *ep.Runtime
		}
		name := ep.Name
		if name == "" {
			name = fmt.Sprintf("Épisode %d", ep.EpisodeNumber)
		}
		episodes = append(episodes, TMDBEpisodeSummary{
			Number:    ep.EpisodeNumber,
			Name:      name,
			Overview:  ep.Overview,
			StillPath: still,
			AirDate:   ep.AirDate,
			Runtime:   runtime,
			Rating:    ep.VoteAverage,
		})
	}
	tmdbEpisodesCache.Put(key, episodes)
	return episodes
}

// mediaHubSeasonStatuses maps season number to MediaHub status for a show.
// A nil result means MediaHub could not answer — callers must then treat every
// season as non-requestable rather than assuming it is free to request.
func mediaHubSeasonStatuses(tmdbID int) map[int]string {
	if tmdbID <= 0 {
		return nil
	}
	if strings.TrimSpace(config.MediaHubURL()) == "" ||
		strings.TrimSpace(config.MediaHubAPIKey()) == "" {
		return nil
	}

	key := strconv.Itoa(tmdbID)
	if cached, ok := mediaHubStatusCache.Get(key); ok {
		return cached
	}

	availability := fetchMediaHubAvailability(tmdbID, "tv", tmdbFastClient)
	if availability == nil {
		return nil
	}

	statuses := make(map[int]string, len(availability.Seasons))
	for _, season := range availability.Seasons {
		if season.Status == "" {
			continue
		}
		statuses[season.SeasonNumber] = season.Status
	}
	mediaHubStatusCache.Put(key, statuses)
	return statuses
}

// invalidateMediaHubStatus drops the cached statuses for a show so a freshly
// sent request is not masked by a stale "unknown" for up to 30s.
func invalidateMediaHubStatus(tmdbID int) {
	if tmdbID <= 0 {
		return
	}
	mediaHubStatusCache.Delete(strconv.Itoa(tmdbID))
}
