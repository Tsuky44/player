package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"

	"project-player/server/config"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

const tmdbRequestTimeout = 15

func tmdbRequestAPIKey() string {
	return config.TMDBAPIKey()
}

func tmdbRequestLanguage() string {
	return config.TMDBLanguage()
}

type tmdbCatalogRow struct {
	ID           int     `json:"id"`
	MediaType    string  `json:"media_type"`
	Title        string  `json:"title"`
	Name         string  `json:"name"`
	Overview     string  `json:"overview"`
	PosterPath   *string `json:"poster_path"`
	BackdropPath *string `json:"backdrop_path"`
	ReleaseDate  string  `json:"release_date"`
	FirstAirDate string  `json:"first_air_date"`
	VoteAverage  float64 `json:"vote_average"`
}

type tmdbCatalogResponse struct {
	Page       int              `json:"page"`
	TotalPages int              `json:"total_pages"`
	Results    []tmdbCatalogRow `json:"results"`
}

func fetchTMDBCatalogPage(client *http.Client, tmdbURL string, raw interface{}) error {
	resp, err := client.Get(tmdbURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("tmdb status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(raw)
}

func sortDiscoverResults(results []tmdbCatalogRow, sortBy string) {
	field, desc := "popularity", true
	if parts := strings.Split(sortBy, "."); len(parts) == 2 {
		field = parts[0]
		desc = parts[1] == "desc"
	}
	less := func(i, j int) bool {
		a, b := results[i], results[j]
		switch field {
		case "vote_average":
			if desc {
				return a.VoteAverage > b.VoteAverage
			}
			return a.VoteAverage < b.VoteAverage
		case "release_date", "primary_release_date":
			da := a.ReleaseDate
			if da == "" {
				da = a.FirstAirDate
			}
			db := b.ReleaseDate
			if db == "" {
				db = b.FirstAirDate
			}
			if desc {
				return da > db
			}
			return da < db
		default:
			if desc {
				return a.VoteAverage > b.VoteAverage
			}
			return a.VoteAverage < b.VoteAverage
		}
	}
	for i := 0; i < len(results); i++ {
		for j := i + 1; j < len(results); j++ {
			if less(j, i) {
				results[i], results[j] = results[j], results[i]
			}
		}
	}
}

// TmdbRequestCatalog handles GET /api/requests/catalog.
// It fetches trending media or search results directly from TMDB.
func TmdbRequestCatalog(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "TMDB API key not configured")
		return
	}

	pageStr := r.URL.Query().Get("page")
	page, _ := strconv.Atoi(pageStr)
	if page < 1 {
		page = 1
	}

	mediaType := r.URL.Query().Get("type")
	query := strings.TrimSpace(r.URL.Query().Get("query"))
	discover := parseDiscoverFilters(r.URL.Query())

	lang := tmdbRequestLanguage()
	client := &http.Client{Timeout: tmdbRequestTimeout * 1_000_000_000}

	var raw tmdbCatalogResponse

	var err error
	if query != "" {
		var tmdbURL string
		if mediaType == "movie" {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/search/movie?api_key=%s&language=%s&page=%d&query=%s", apiKey, lang, page, url.QueryEscape(query))
		} else if mediaType == "tv" {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/search/tv?api_key=%s&language=%s&page=%d&query=%s", apiKey, lang, page, url.QueryEscape(query))
		} else {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/search/multi?api_key=%s&language=%s&page=%d&query=%s", apiKey, lang, page, url.QueryEscape(query))
		}
		err = fetchTMDBCatalogPage(client, tmdbURL, &raw)
	} else if discover.active() {
		if mediaType == "movie" || mediaType == "tv" {
			err = fetchTMDBCatalogPage(client, discoverURL(mediaType, apiKey, lang, page, discover), &raw)
		} else {
			raw, err = fetchTMDBDiscoverMixed(client, apiKey, lang, page, discover)
		}
	} else {
		var tmdbURL string
		if mediaType == "movie" {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/trending/movie/week?api_key=%s&language=%s&page=%d", apiKey, lang, page)
		} else if mediaType == "tv" {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/trending/tv/week?api_key=%s&language=%s&page=%d", apiKey, lang, page)
		} else {
			tmdbURL = fmt.Sprintf("https://api.themoviedb.org/3/trending/all/week?api_key=%s&language=%s&page=%d", apiKey, lang, page)
		}
		err = fetchTMDBCatalogPage(client, tmdbURL, &raw)
	}

	if err != nil {
		writeJSONError(w, http.StatusBadGateway, "TMDB request failed")
		return
	}

	results := make([]catalogItem, 0, len(raw.Results))
	for _, item := range raw.Results {
		mt := item.MediaType
		if mt == "" {
			if mediaType == "movie" {
				mt = "movie"
			} else if mediaType == "tv" {
				mt = "tv"
			}
		}
		if mt != "movie" && mt != "tv" {
			continue
		}
		title := item.Title
		if title == "" {
			title = item.Name
		}
		releaseDate := item.ReleaseDate
		if releaseDate == "" {
			releaseDate = item.FirstAirDate
		}
		results = append(results, catalogItem{
			ID:           item.ID,
			MediaType:    mt,
			Title:        title,
			Overview:     item.Overview,
			PosterPath:   item.PosterPath,
			BackdropPath: item.BackdropPath,
			ReleaseDate:  releaseDate,
			Rating:       item.VoteAverage,
			Status:       "unknown",
		})
	}

	enrichCatalogAvailability(results)

	json.NewEncoder(w).Encode(map[string]any{
		"page":       raw.Page,
		"totalPages": raw.TotalPages,
		"results":    results,
	})
}

// enrichCatalogAvailability fills MediaHub availability status on catalog items
// (same green/purple/yellow dots as MediaHub MediaCardStatus).
func enrichCatalogAvailability(items []catalogItem) {
	if len(items) == 0 {
		return
	}
	baseURL := strings.TrimRight(strings.TrimSpace(config.MediaHubURL()), "/")
	apiKey := strings.TrimSpace(config.MediaHubAPIKey())
	if baseURL == "" || apiKey == "" {
		return
	}

	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i := range items {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if av := fetchMediaHubAvailability(items[i].ID, items[i].MediaType, mediaHubHTTPClient); av != nil && av.Status != "" {
				items[i].Status = av.Status
			}
		}(i)
	}
	wg.Wait()
}

// catalogItem is shared by TmdbRequestCatalog and enrichCatalogAvailability.
type catalogItem struct {
	ID           int     `json:"id"`
	MediaType    string  `json:"mediaType"`
	Title        string  `json:"title"`
	Overview     string  `json:"overview"`
	PosterPath   *string `json:"posterPath"`
	BackdropPath *string `json:"backdropPath"`
	ReleaseDate  string  `json:"releaseDate"`
	Rating       float64 `json:"rating"`
	Status       string  `json:"status"`
}

// TmdbRequestDetails handles GET /api/requests/media/:id.
// It fetches rich media details directly from TMDB via the existing indexer.
func TmdbRequestDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "TMDB API key not configured")
		return
	}

	tmdbID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || tmdbID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}

	rawType := r.URL.Query().Get("type")
	var mediaType models.MediaType
	if rawType == "tv" {
		mediaType = models.TypeShow
	} else if rawType == "movie" {
		mediaType = models.TypeMovie
	} else {
		writeJSONError(w, http.StatusBadRequest, "Missing or invalid type parameter")
		return
	}

	details := indexer.FetchMediaCatalogDetails(tmdbID, mediaType)
	if details == nil {
		writeJSONError(w, http.StatusNotFound, "Media not found on TMDB")
		return
	}

	type seasonInfo struct {
		Number       int    `json:"number"`
		Name         string `json:"name"`
		EpisodeCount int    `json:"episodeCount"`
		PosterPath   string `json:"posterPath,omitempty"`
		Status       string `json:"status"`
	}

	// Fetch seasons for TV shows
	var seasons []seasonInfo
	if mediaType == models.TypeShow {
		lang := tmdbRequestLanguage()
		client := &http.Client{Timeout: tmdbRequestTimeout * 1_000_000_000}
		url := fmt.Sprintf("https://api.themoviedb.org/3/tv/%d?api_key=%s&language=%s", tmdbID, apiKey, lang)
		resp, err := client.Get(url)
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var tvResp struct {
					Seasons []struct {
						SeasonNumber int     `json:"season_number"`
						Name         string  `json:"name"`
						EpisodeCount int     `json:"episode_count"`
						PosterPath   *string `json:"poster_path"`
					} `json:"seasons"`
				}
				if json.NewDecoder(resp.Body).Decode(&tvResp) == nil {
					for _, s := range tvResp.Seasons {
						if s.SeasonNumber <= 0 {
							continue
						}
						poster := ""
						if s.PosterPath != nil {
							poster = *s.PosterPath
						}
						seasons = append(seasons, seasonInfo{
							Number:       s.SeasonNumber,
							Name:         s.Name,
							EpisodeCount: s.EpisodeCount,
							PosterPath:   poster,
							Status:       "unknown",
						})
					}
				}
			}
		}
	}

	type castMember struct {
		TMDBID     int    `json:"tmdbId"`
		Name       string `json:"name"`
		Character  string `json:"character"`
		ProfileURL string `json:"profileUrl,omitempty"`
	}

	cast := make([]castMember, 0, len(details.Cast))
	for _, c := range details.Cast {
		cast = append(cast, castMember{
			TMDBID:     c.TMDBID,
			Name:       c.Name,
			Character:  c.Character,
			ProfileURL: c.ProfileURL,
		})
	}

	mtStr := "movie"
	if mediaType == models.TypeShow {
		mtStr = "tv"
	}

	// Enrich with MediaHub/Sonarr availability (same logic as MediaHub badges).
	status := "unknown"
	if availability := fetchMediaHubAvailability(tmdbID, mtStr, mediaHubHTTPClient); availability != nil {
		if availability.Status != "" {
			status = availability.Status
		}
		if mediaType == models.TypeShow && len(availability.Seasons) > 0 {
			byNumber := make(map[int]string, len(availability.Seasons))
			for _, s := range availability.Seasons {
				if s.Status == "" {
					continue
				}
				byNumber[s.SeasonNumber] = s.Status
			}
			for i := range seasons {
				if st, ok := byNumber[seasons[i].Number]; ok {
					seasons[i].Status = st
				}
			}
		}
	}

	json.NewEncoder(w).Encode(map[string]any{
		"id":               tmdbID,
		"mediaType":        mtStr,
		"title":            details.Title,
		"originalTitle":    details.OriginalTitle,
		"tagline":          details.Tagline,
		"overview":         details.Overview,
		"posterPath":       extractPath(details.PosterURL),
		"backdropPath":     extractPath(details.BackdropURL),
		"logoPath":         extractPath(details.LogoURL),
		"releaseDate":      details.ReleaseDate,
		"rating":           details.VoteAverage,
		"runtime":          details.Runtime,
		"genres":           details.Genres,
		"studios":          details.Studios,
		"countries":        details.Countries,
		"originalLanguage": details.OriginalLang,
		"tmdbStatus":       details.Status,
		"status":           status,
		"director":         details.Director,
		"writers":          details.Writers,
		"editors":          details.Editors,
		"keywords":         details.Keywords,
		"trailerKey":       details.TrailerKey,
		"budget":           details.Budget,
		"revenue":          details.Revenue,
		"cast":             cast,
		"seasons":          seasons,
		"numberOfSeasons":  details.NumberOfSeasons,
		"numberOfEpisodes": details.NumberOfEpisodes,
		"recommendations":  mapRelatedForRequest(details.Recommendations, mtStr),
		"similar":          mapRelatedForRequest(details.Similar, mtStr),
	})
}

// TmdbRequestSeasonEpisodes handles GET /api/requests/media/:id/seasons/:num/episodes.
// It returns TMDB episode metadata for a given TV season (lazy-loaded by the client).
func TmdbRequestSeasonEpisodes(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "TMDB API key not configured")
		return
	}

	tmdbID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || tmdbID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid media ID")
		return
	}
	seasonNum, err := strconv.Atoi(ps.ByName("num"))
	if err != nil || seasonNum < 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid season number")
		return
	}

	lang := tmdbRequestLanguage()
	client := &http.Client{Timeout: tmdbRequestTimeout * 1_000_000_000}
	reqURL := fmt.Sprintf(
		"https://api.themoviedb.org/3/tv/%d/season/%d?api_key=%s&language=%s",
		tmdbID, seasonNum, apiKey, lang,
	)
	resp, err := client.Get(reqURL)
	if err != nil {
		writeJSONError(w, http.StatusBadGateway, "Failed to fetch season from TMDB")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		writeJSONError(w, http.StatusNotFound, "Season not found on TMDB")
		return
	}
	if resp.StatusCode != http.StatusOK {
		writeJSONError(w, http.StatusBadGateway, "TMDB returned an error")
		return
	}

	var tmdbResp struct {
		Episodes []struct {
			ID            int     `json:"id"`
			Name          string  `json:"name"`
			Overview      string  `json:"overview"`
			StillPath     *string `json:"still_path"`
			EpisodeNumber int     `json:"episode_number"`
			AirDate       string  `json:"air_date"`
			VoteAverage   float64 `json:"vote_average"`
			Runtime       *int    `json:"runtime"`
		} `json:"episodes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tmdbResp); err != nil {
		writeJSONError(w, http.StatusBadGateway, "Failed to decode TMDB response")
		return
	}

	type episodeInfo struct {
		ID            int     `json:"id"`
		Number        int     `json:"number"`
		Name          string  `json:"name"`
		Overview      string  `json:"overview"`
		StillPath     string  `json:"stillPath,omitempty"`
		AirDate       string  `json:"airDate,omitempty"`
		Runtime       int     `json:"runtime,omitempty"`
		VoteAverage   float64 `json:"rating"`
	}

	episodes := make([]episodeInfo, 0, len(tmdbResp.Episodes))
	for _, ep := range tmdbResp.Episodes {
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
		episodes = append(episodes, episodeInfo{
			ID:          ep.ID,
			Number:      ep.EpisodeNumber,
			Name:        name,
			Overview:    ep.Overview,
			StillPath:   still,
			AirDate:     ep.AirDate,
			Runtime:     runtime,
			VoteAverage: ep.VoteAverage,
		})
	}

	_ = json.NewEncoder(w).Encode(map[string]any{
		"tmdbId":       tmdbID,
		"seasonNumber": seasonNum,
		"episodes":     episodes,
	})
}

func mapRelatedForRequest(items []models.RelatedMedia, fallbackType string) []map[string]any {
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		mt := fallbackType
		if item.Type == models.TypeShow {
			mt = "tv"
		} else if item.Type == models.TypeMovie {
			mt = "movie"
		}
		out = append(out, map[string]any{
			"id":           item.ID,
			"mediaType":    mt,
			"title":        item.Title,
			"overview":     item.Overview,
			"posterPath":   extractPath(item.PosterURL),
			"backdropPath": extractPath(item.BackdropURL),
			"releaseDate":  item.ReleaseDate,
			"rating":       item.VoteAverage,
			"status":       "unknown",
		})
	}
	return out
}

// extractPath extracts the relative TMDB path from a full image URL.
// e.g. "https://image.tmdb.org/t/p/w500/abc.jpg" -> "/abc.jpg"
func extractPath(fullURL string) string {
	if fullURL == "" {
		return ""
	}
	const marker = "/t/p/"
	idx := strings.Index(fullURL, marker)
	if idx < 0 {
		return ""
	}
	rest := fullURL[idx+len(marker):]
	slashIdx := strings.Index(rest, "/")
	if slashIdx < 0 {
		return ""
	}
	return rest[slashIdx:]
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
