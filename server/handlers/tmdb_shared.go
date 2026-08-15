package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/config"
	"project-player/server/httpx"
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

type cacheEntry[T any] struct {
	value    T
	storedAt time.Time
}

// ttlCache is a tiny in-memory cache. Entries are never evicted actively; the
// key space here is bounded by the number of shows in the library.
type ttlCache[T any] struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[string]cacheEntry[T]
}

func newTTLCache[T any](ttl time.Duration) *ttlCache[T] {
	return &ttlCache[T]{ttl: ttl, entries: map[string]cacheEntry[T]{}}
}

func (c *ttlCache[T]) get(key string) (T, bool) {
	c.mu.RLock()
	entry, ok := c.entries[key]
	c.mu.RUnlock()
	if !ok || time.Since(entry.storedAt) > c.ttl {
		var zero T
		return zero, false
	}
	return entry.value, true
}

func (c *ttlCache[T]) put(key string, value T) {
	c.mu.Lock()
	c.entries[key] = cacheEntry[T]{value: value, storedAt: time.Now()}
	c.mu.Unlock()
}

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
	tmdbSeasonsCache    = newTTLCache[[]TMDBSeasonSummary](tmdbSeasonsCacheTTL)
	tmdbEpisodesCache   = newTTLCache[[]TMDBEpisodeSummary](tmdbEpisodesCacheTTL)
	mediaHubStatusCache = newTTLCache[map[int]string](mediaHubStatusCacheTTL)
)

// FetchTMDBShowSeasons returns every season TMDB knows for a show, specials
// (season 0) excluded. Returns nil when TMDB is unreachable or unconfigured.
func FetchTMDBShowSeasons(tmdbID int) []TMDBSeasonSummary {
	if tmdbID <= 0 {
		return nil
	}
	key := strconv.Itoa(tmdbID)
	if cached, ok := tmdbSeasonsCache.get(key); ok {
		return cached
	}

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		return nil
	}
	target := fmt.Sprintf(
		"https://api.themoviedb.org/3/tv/%d?api_key=%s&language=%s",
		tmdbID, apiKey, tmdbRequestLanguage(),
	)
	resp, err := tmdbFastClient.Get(target)
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
	tmdbSeasonsCache.put(key, seasons)
	return seasons
}

// FetchTMDBSeasonEpisodes returns the episodes TMDB lists for one season.
// Returns nil when TMDB is unreachable or the season does not exist.
func FetchTMDBSeasonEpisodes(tmdbID, seasonNumber int) []TMDBEpisodeSummary {
	if tmdbID <= 0 || seasonNumber < 0 {
		return nil
	}
	key := fmt.Sprintf("%d/%d", tmdbID, seasonNumber)
	if cached, ok := tmdbEpisodesCache.get(key); ok {
		return cached
	}

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		return nil
	}
	target := fmt.Sprintf(
		"https://api.themoviedb.org/3/tv/%d/season/%d?api_key=%s&language=%s",
		tmdbID, seasonNumber, apiKey, tmdbRequestLanguage(),
	)
	resp, err := tmdbFastClient.Get(target)
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
	tmdbEpisodesCache.put(key, episodes)
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
	if cached, ok := mediaHubStatusCache.get(key); ok {
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
	mediaHubStatusCache.put(key, statuses)
	return statuses
}

// invalidateMediaHubStatus drops the cached statuses for a show so a freshly
// sent request is not masked by a stale "unknown" for up to 30s.
func invalidateMediaHubStatus(tmdbID int) {
	if tmdbID <= 0 {
		return
	}
	mediaHubStatusCache.mu.Lock()
	delete(mediaHubStatusCache.entries, strconv.Itoa(tmdbID))
	mediaHubStatusCache.mu.Unlock()
}
