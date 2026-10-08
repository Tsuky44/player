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
	"project-player/server/httpx"
	"project-player/server/indexer"
	"project-player/server/models"
	"project-player/server/safego"
	"project-player/server/tmdb"

	"github.com/julienschmidt/httprouter"
)

func tmdbRequestAPIKey() string {
	return config.TMDBAPIKey()
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
	resp, err := tmdb.Get(client, tmdbURL)
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

	lang := languageOf(r).tmdbLocale()
	client := httpx.Catalog

	var raw tmdbCatalogResponse

	var err error
	if query != "" {
		var tmdbURL string
		if mediaType == "movie" {
			tmdbURL = fmt.Sprintf("/search/movie?language=%s&page=%d&query=%s", lang, page, url.QueryEscape(query))
		} else if mediaType == "tv" {
			tmdbURL = fmt.Sprintf("/search/tv?language=%s&page=%d&query=%s", lang, page, url.QueryEscape(query))
		} else {
			tmdbURL = fmt.Sprintf("/search/multi?language=%s&page=%d&query=%s", lang, page, url.QueryEscape(query))
		}
		err = fetchTMDBCatalogPage(client, tmdbURL, &raw)
	} else if discover.active() {
		if mediaType == "movie" || mediaType == "tv" {
			err = fetchTMDBCatalogPage(client, discoverURL(mediaType, lang, page, discover), &raw)
		} else {
			raw, err = fetchTMDBDiscoverMixed(client, lang, page, discover)
		}
	} else {
		var tmdbURL string
		if mediaType == "movie" {
			tmdbURL = fmt.Sprintf("/trending/movie/week?language=%s&page=%d", lang, page)
		} else if mediaType == "tv" {
			tmdbURL = fmt.Sprintf("/trending/tv/week?language=%s&page=%d", lang, page)
		} else {
			tmdbURL = fmt.Sprintf("/trending/all/week?language=%s&page=%d", lang, page)
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

	json.NewEncoder(w).Encode(requestCatalogResponse{
		Page:       raw.Page,
		TotalPages: raw.TotalPages,
		Results:    results,
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
			defer safego.Recover("handlers/tmdb_requests.go:218")
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

	details := indexer.FetchMediaCatalogDetails(tmdbID, mediaType, languageOf(r).code)
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
		lang := languageOf(r).tmdbLocale()
		client := httpx.Catalog
		url := fmt.Sprintf("/tv/%d?language=%s", tmdbID, lang)
		resp, err := tmdb.Get(client, url)
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

	json.NewEncoder(w).Encode(struct {
		ID               int                  `json:"id"`
		MediaType        string               `json:"mediaType"`
		Title            string               `json:"title"`
		OriginalTitle    string               `json:"originalTitle"`
		Tagline          string               `json:"tagline"`
		Overview         string               `json:"overview"`
		PosterPath       string               `json:"posterPath"`
		BackdropPath     string               `json:"backdropPath"`
		LogoPath         string               `json:"logoPath"`
		ReleaseDate      string               `json:"releaseDate"`
		Rating           float64              `json:"rating"`
		Runtime          int                  `json:"runtime"`
		Genres           []string             `json:"genres"`
		Studios          []string             `json:"studios"`
		Countries        []string             `json:"countries"`
		OriginalLanguage string               `json:"originalLanguage"`
		TMDBStatus       string               `json:"tmdbStatus"`
		Status           string               `json:"status"`
		Director         string               `json:"director"`
		Writers          []string             `json:"writers"`
		Editors          []string             `json:"editors"`
		Keywords         []string             `json:"keywords"`
		TrailerKey       string               `json:"trailerKey"`
		Budget           int64                `json:"budget"`
		Revenue          int64                `json:"revenue"`
		Cast             []castMember         `json:"cast"`
		Seasons          []seasonInfo         `json:"seasons"`
		NumberOfSeasons  int                  `json:"numberOfSeasons"`
		NumberOfEpisodes int                  `json:"numberOfEpisodes"`
		Recommendations  []requestRelatedItem `json:"recommendations"`
		Similar          []requestRelatedItem `json:"similar"`
	}{
		ID:               tmdbID,
		MediaType:        mtStr,
		Title:            details.Title,
		OriginalTitle:    details.OriginalTitle,
		Tagline:          details.Tagline,
		Overview:         details.Overview,
		PosterPath:       extractPath(details.PosterURL),
		BackdropPath:     extractPath(details.BackdropURL),
		LogoPath:         extractPath(details.LogoURL),
		ReleaseDate:      details.ReleaseDate,
		Rating:           details.VoteAverage,
		Runtime:          details.Runtime,
		Genres:           details.Genres,
		Studios:          details.Studios,
		Countries:        details.Countries,
		OriginalLanguage: details.OriginalLang,
		TMDBStatus:       details.Status,
		Status:           status,
		Director:         details.Director,
		Writers:          details.Writers,
		Editors:          details.Editors,
		Keywords:         details.Keywords,
		TrailerKey:       details.TrailerKey,
		Budget:           details.Budget,
		Revenue:          details.Revenue,
		Cast:             cast,
		Seasons:          seasons,
		NumberOfSeasons:  details.NumberOfSeasons,
		NumberOfEpisodes: details.NumberOfEpisodes,
		Recommendations:  mapRelatedForRequest(details.Recommendations, mtStr),
		Similar:          mapRelatedForRequest(details.Similar, mtStr),
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

	lang := languageOf(r).tmdbLocale()
	client := httpx.Catalog
	reqURL := fmt.Sprintf(
		"/tv/%d/season/%d?language=%s",
		tmdbID, seasonNum, lang,
	)
	resp, err := tmdb.Get(client, reqURL)
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
		ID          int     `json:"id"`
		Number      int     `json:"number"`
		Name        string  `json:"name"`
		Overview    string  `json:"overview"`
		StillPath   string  `json:"stillPath,omitempty"`
		AirDate     string  `json:"airDate,omitempty"`
		Runtime     int     `json:"runtime,omitempty"`
		VoteAverage float64 `json:"rating"`
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

	_ = json.NewEncoder(w).Encode(struct {
		TMDBID       int           `json:"tmdbId"`
		SeasonNumber int           `json:"seasonNumber"`
		Episodes     []episodeInfo `json:"episodes"`
	}{tmdbID, seasonNum, episodes})
}

func mapRelatedForRequest(items []models.RelatedMedia, fallbackType string) []requestRelatedItem {
	out := make([]requestRelatedItem, 0, len(items))
	for _, item := range items {
		mt := fallbackType
		if item.Type == models.TypeShow {
			mt = "tv"
		} else if item.Type == models.TypeMovie {
			mt = "movie"
		}
		out = append(out, requestRelatedItem{
			ID:           item.ID,
			MediaType:    mt,
			Title:        item.Title,
			Overview:     item.Overview,
			PosterPath:   extractPath(item.PosterURL),
			BackdropPath: extractPath(item.BackdropURL),
			ReleaseDate:  item.ReleaseDate,
			Rating:       item.VoteAverage,
			Status:       "unknown",
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
