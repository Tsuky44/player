package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/julienschmidt/httprouter"
)

type discoverFilters struct {
	SortBy         string
	StartDate      string
	EndDate        string
	Language       string
	Genres         []int
	MinDuration    string
	MaxDuration    string
	WatchRegion    string
	WatchProviders []int
}

func defaultDiscoverFilters() discoverFilters {
	return discoverFilters{
		SortBy:      "popularity.desc",
		Language:    "all",
		WatchRegion: "FR",
	}
}

func parseDiscoverFilters(q url.Values) discoverFilters {
	sortBy := strings.TrimSpace(q.Get("sort_by"))
	if sortBy == "" {
		sortBy = "popularity.desc"
	}
	region := strings.TrimSpace(q.Get("watch_region"))
	if region == "" {
		region = "FR"
	}
	return discoverFilters{
		SortBy:         sortBy,
		StartDate:      strings.TrimSpace(q.Get("start_date")),
		EndDate:        strings.TrimSpace(q.Get("end_date")),
		Language:       strings.TrimSpace(q.Get("language")),
		Genres:         parseIntList(q.Get("genres"), ","),
		MinDuration:    strings.TrimSpace(q.Get("min_duration")),
		MaxDuration:    strings.TrimSpace(q.Get("max_duration")),
		WatchRegion:    region,
		WatchProviders: parseIntList(q.Get("watch_providers"), "|"),
	}
}

func parseIntList(raw, sep string) []int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, sep)
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil || n <= 0 {
			continue
		}
		out = append(out, n)
	}
	return out
}

func (f discoverFilters) active() bool {
	d := defaultDiscoverFilters()
	if f.StartDate != "" || f.EndDate != "" {
		return true
	}
	if f.Language != "" && f.Language != "all" {
		return true
	}
	if f.SortBy != "" && f.SortBy != d.SortBy {
		return true
	}
	if len(f.Genres) > 0 {
		return true
	}
	if f.MinDuration != "" || f.MaxDuration != "" {
		return true
	}
	if f.WatchRegion != "" && f.WatchRegion != d.WatchRegion {
		return true
	}
	if len(f.WatchProviders) > 0 {
		return true
	}
	return false
}

func discoverURL(mediaType, apiKey, lang string, page int, f discoverFilters) string {
	u := url.URL{
		Scheme: "https",
		Host:   "api.themoviedb.org",
		Path:   "/3/discover/" + mediaType,
	}
	q := u.Query()
	q.Set("api_key", apiKey)
	q.Set("language", lang)
	q.Set("page", strconv.Itoa(page))
	q.Set("sort_by", f.SortBy)
	q.Set("vote_count.gte", "0")
	dateGte := "primary_release_date.gte"
	dateLte := "primary_release_date.lte"
	if mediaType == "tv" {
		dateGte = "first_air_date.gte"
		dateLte = "first_air_date.lte"
	}
	if f.StartDate != "" {
		q.Set(dateGte, f.StartDate)
	}
	if f.EndDate != "" {
		q.Set(dateLte, f.EndDate)
	}
	if f.Language != "" && f.Language != "all" {
		q.Set("with_original_language", f.Language)
	}
	if len(f.Genres) > 0 {
		parts := make([]string, len(f.Genres))
		for i, g := range f.Genres {
			parts[i] = strconv.Itoa(g)
		}
		q.Set("with_genres", strings.Join(parts, ","))
	}
	if f.MinDuration != "" {
		q.Set("with_runtime.gte", f.MinDuration)
	}
	if f.MaxDuration != "" {
		q.Set("with_runtime.lte", f.MaxDuration)
	}
	if f.WatchRegion != "" {
		q.Set("watch_region", f.WatchRegion)
	}
	if len(f.WatchProviders) > 0 {
		parts := make([]string, len(f.WatchProviders))
		for i, p := range f.WatchProviders {
			parts[i] = strconv.Itoa(p)
		}
		q.Set("with_watch_providers", strings.Join(parts, "|"))
	}
	u.RawQuery = q.Encode()
	return u.String()
}

// MediaHub discoverMixed genre mapping (tmdb.ts).
func expandGenresForMovie(ids []int) []int {
	var out []int
	for _, id := range ids {
		switch id {
		case 10759:
			out = append(out, 28, 12)
		case 10765:
			out = append(out, 878, 14)
		case 10768:
			out = append(out, 10752)
		case 10762, 10763, 10764, 10766, 10767:
			// no movie equivalent
		default:
			out = append(out, id)
		}
	}
	return uniquePositiveInts(out)
}

func expandGenresForTV(ids []int) []int {
	var out []int
	for _, id := range ids {
		switch id {
		case 28, 12:
			out = append(out, 10759)
		case 878, 14:
			out = append(out, 10765)
		case 10752:
			out = append(out, 10768)
		default:
			out = append(out, id)
		}
	}
	return uniquePositiveInts(out)
}

func uniquePositiveInts(in []int) []int {
	seen := make(map[int]struct{}, len(in))
	out := make([]int, 0, len(in))
	for _, n := range in {
		if n <= 0 {
			continue
		}
		if _, ok := seen[n]; ok {
			continue
		}
		seen[n] = struct{}{}
		out = append(out, n)
	}
	return out
}

func fetchTMDBDiscoverMixed(client *http.Client, apiKey, lang string, page int, f discoverFilters) (tmdbCatalogResponse, error) {
	movieF := f
	movieF.Genres = expandGenresForMovie(f.Genres)
	tvF := f
	tvF.Genres = expandGenresForTV(f.Genres)

	var movies, series tmdbCatalogResponse
	if err := fetchTMDBCatalogPage(client, discoverURL("movie", apiKey, lang, page, movieF), &movies); err != nil {
		return tmdbCatalogResponse{}, err
	}
	if err := fetchTMDBCatalogPage(client, discoverURL("tv", apiKey, lang, page, tvF), &series); err != nil {
		return tmdbCatalogResponse{}, err
	}

	combined := make([]tmdbCatalogRow, 0, len(movies.Results)+len(series.Results))
	for _, item := range movies.Results {
		item.MediaType = "movie"
		combined = append(combined, item)
	}
	for _, item := range series.Results {
		item.MediaType = "tv"
		combined = append(combined, item)
	}

	sortDiscoverResults(combined, f.SortBy)

	totalPages := movies.TotalPages
	if series.TotalPages > totalPages {
		totalPages = series.TotalPages
	}
	return tmdbCatalogResponse{
		Page:       page,
		TotalPages: totalPages,
		Results:    combined,
	}, nil
}

// TmdbRequestFilterOptions handles GET /api/requests/filter-options?type=all|movie|tv
func TmdbRequestFilterOptions(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "TMDB API key not configured")
		return
	}

	mediaType := r.URL.Query().Get("type")
	lang := tmdbRequestLanguage()
	client := &http.Client{Timeout: tmdbRequestTimeout * 1_000_000_000}

	type genreRow struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}

	fetchGenres := func(t string) ([]genreRow, error) {
		u := fmt.Sprintf("https://api.themoviedb.org/3/genre/%s/list?api_key=%s&language=%s", t, apiKey, lang)
		var raw struct {
			Genres []genreRow `json:"genres"`
		}
		if err := fetchTMDBCatalogPage(client, u, &raw); err != nil {
			return nil, err
		}
		return raw.Genres, nil
	}

	var genres []genreRow
	var err error
	switch mediaType {
	case "movie":
		genres, err = fetchGenres("movie")
	case "tv":
		genres, err = fetchGenres("tv")
	default:
		movieG, errM := fetchGenres("movie")
		tvG, errT := fetchGenres("tv")
		if errM != nil && errT != nil {
			writeJSONError(w, http.StatusBadGateway, "Failed to fetch genres")
			return
		}
		byID := map[int]genreRow{}
		for _, g := range movieG {
			byID[g.ID] = g
		}
		for _, g := range tvG {
			byID[g.ID] = g
		}
		genres = make([]genreRow, 0, len(byID))
		for _, g := range byID {
			genres = append(genres, g)
		}
		sort.Slice(genres, func(i, j int) bool {
			return genres[i].Name < genres[j].Name
		})
	}
	if err != nil {
		writeJSONError(w, http.StatusBadGateway, "Failed to fetch genres")
		return
	}

	json.NewEncoder(w).Encode(map[string]any{"genres": genres})
}

// TmdbRequestWatchProviders handles GET /api/requests/watch-providers
func TmdbRequestWatchProviders(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")
	apiKey := tmdbRequestAPIKey()
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "TMDB API key not configured")
		return
	}

	mediaType := r.URL.Query().Get("type")
	region := strings.TrimSpace(r.URL.Query().Get("region"))
	if region == "" {
		region = "FR"
	}
	lang := tmdbRequestLanguage()
	client := &http.Client{Timeout: tmdbRequestTimeout * 1_000_000_000}

	type providerRow struct {
		ProviderID   int    `json:"provider_id"`
		ProviderName string `json:"provider_name"`
		LogoPath     string `json:"logo_path"`
	}

	fetchProviders := func(t string) ([]providerRow, error) {
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/watch/providers/%s?api_key=%s&language=%s&watch_region=%s",
			t, apiKey, lang, url.QueryEscape(region),
		)
		var raw struct {
			Results []providerRow `json:"results"`
		}
		if err := fetchTMDBCatalogPage(client, u, &raw); err != nil {
			return nil, err
		}
		return raw.Results, nil
	}

	var providers []providerRow
	switch mediaType {
	case "movie":
		var err error
		providers, err = fetchProviders("movie")
		if err != nil {
			writeJSONError(w, http.StatusBadGateway, "Failed to fetch providers")
			return
		}
	case "tv":
		var err error
		providers, err = fetchProviders("tv")
		if err != nil {
			writeJSONError(w, http.StatusBadGateway, "Failed to fetch providers")
			return
		}
	default:
		movieP, errM := fetchProviders("movie")
		tvP, errT := fetchProviders("tv")
		if errM != nil && errT != nil {
			writeJSONError(w, http.StatusBadGateway, "Failed to fetch providers")
			return
		}
		byID := map[int]providerRow{}
		for _, p := range movieP {
			byID[p.ProviderID] = p
		}
		for _, p := range tvP {
			byID[p.ProviderID] = p
		}
		providers = make([]providerRow, 0, len(byID))
		for _, p := range byID {
			providers = append(providers, p)
		}
		sort.Slice(providers, func(i, j int) bool {
			return providers[i].ProviderName < providers[j].ProviderName
		})
	}

	json.NewEncoder(w).Encode(map[string]any{"providers": providers})
}
