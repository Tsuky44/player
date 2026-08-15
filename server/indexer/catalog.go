package indexer

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"project-player/server/httpx"
	"project-player/server/models"
)

// ---- Live TMDB "catalog" details (cast, genres, rating, backdrop…) ----
//
// Unlike the indexer's enrich path (which persists a handful of fields to the
// DB), this fetches the full rich payload on demand for the detail pages and
// keeps it in a short-lived in-memory cache so opening the same title twice
// doesn't hammer TMDB.

type tmdbPerson struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Character   string `json:"character"`
	Job         string `json:"job"`
	ProfilePath string `json:"profile_path"`
	Order       int    `json:"order"`
}

type tmdbCatalogResponse struct {
	Title            string  `json:"title"`
	Name             string  `json:"name"`
	OriginalTitle    string  `json:"original_title"`
	OriginalName     string  `json:"original_name"`
	OriginalLanguage string  `json:"original_language"`
	Tagline          string  `json:"tagline"`
	Overview         string  `json:"overview"`
	PosterPath       string  `json:"poster_path"`
	BackdropPath     string  `json:"backdrop_path"`
	ReleaseDate      string  `json:"release_date"`
	FirstAirDate     string  `json:"first_air_date"`
	Runtime          int     `json:"runtime"`
	EpisodeRunTime   []int   `json:"episode_run_time"`
	Status           string  `json:"status"`
	VoteAverage      float64 `json:"vote_average"`
	Budget           int64   `json:"budget"`
	Revenue          int64   `json:"revenue"`
	NumberOfSeasons  int     `json:"number_of_seasons"`
	NumberOfEpisodes int     `json:"number_of_episodes"`
	Genres           []struct {
		Name string `json:"name"`
	} `json:"genres"`
	ProductionCompanies []struct {
		Name string `json:"name"`
	} `json:"production_companies"`
	ProductionCountries []struct {
		Name string `json:"name"`
	} `json:"production_countries"`
	BelongsToCollection *struct {
		ID           int    `json:"id"`
		Name         string `json:"name"`
		BackdropPath string `json:"backdrop_path"`
		PosterPath   string `json:"poster_path"`
	} `json:"belongs_to_collection"`
	Credits struct {
		Cast []tmdbPerson `json:"cast"`
		Crew []tmdbPerson `json:"crew"`
	} `json:"credits"`
	AggregateCredits struct {
		Cast []struct {
			ID          int    `json:"id"`
			Name        string `json:"name"`
			ProfilePath string `json:"profile_path"`
			Order       int    `json:"order"`
			Roles       []struct {
				Character string `json:"character"`
			} `json:"roles"`
		} `json:"cast"`
		Crew []struct {
			Name string `json:"name"`
			Jobs []struct {
				Job string `json:"job"`
			} `json:"jobs"`
		} `json:"crew"`
	} `json:"aggregate_credits"`
	Images struct {
		Logos []tmdbLogoImage `json:"logos"`
	} `json:"images"`
	Videos struct {
		Results []struct {
			Key  string `json:"key"`
			Site string `json:"site"`
			Type string `json:"type"`
		} `json:"results"`
	} `json:"videos"`
	Keywords struct {
		Keywords []struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		} `json:"keywords"`
		Results []struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		} `json:"results"`
	} `json:"keywords"`
	Recommendations struct {
		Results []tmdbRelatedItem `json:"results"`
	} `json:"recommendations"`
	Similar struct {
		Results []tmdbRelatedItem `json:"results"`
	} `json:"similar"`
}

type tmdbRelatedItem struct {
	ID           int     `json:"id"`
	Title        string  `json:"title"`
	Name         string  `json:"name"`
	Overview     string  `json:"overview"`
	PosterPath   string  `json:"poster_path"`
	BackdropPath string  `json:"backdrop_path"`
	ReleaseDate  string  `json:"release_date"`
	FirstAirDate string  `json:"first_air_date"`
	VoteAverage  float64 `json:"vote_average"`
	MediaType    string  `json:"media_type"`
}

type tmdbLogoImage struct {
	FilePath string `json:"file_path"`
	Iso6391  string `json:"iso_639_1"`
}

type tmdbImagesResponse struct {
	Logos []tmdbLogoImage `json:"logos"`
}

type catalogCacheEntry struct {
	details *models.MediaDetails
	stored  time.Time
}

var (
	catalogCache   = map[string]catalogCacheEntry{}
	catalogCacheMu sync.RWMutex
)

const catalogCacheTTL = 6 * time.Hour

func profileURLFromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/w300" + path
}

func backdropURLFromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/w1280" + path
}

func logoURLFromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/original" + path
}

func pickBestLogoURLFromLogos(logos []tmdbLogoImage) string {
	if len(logos) == 0 {
		return ""
	}
	// Same priority as MediaHub MediaPageContent: fr → en → first available.
	for _, lang := range []string{"fr", "en"} {
		for _, l := range logos {
			if l.FilePath != "" && l.Iso6391 == lang {
				return logoURLFromPath(l.FilePath)
			}
		}
	}
	for _, l := range logos {
		if l.FilePath != "" {
			return logoURLFromPath(l.FilePath)
		}
	}
	return ""
}

func pickBestLogoURL(r *tmdbCatalogResponse) string {
	return pickBestLogoURLFromLogos(r.Images.Logos)
}

// fetchTMDBLogoURL loads title logos from the dedicated TMDB /images endpoint
// (more reliable than append_to_response alone).
func fetchTMDBLogoURL(tmdbID int, mediaType models.MediaType) string {
	apiKey := tmdbAPIKey()
	if apiKey == "" || tmdbID <= 0 {
		return ""
	}
	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}
	u := fmt.Sprintf(
		"https://api.themoviedb.org/3/%s/%d/images?api_key=%s&include_image_language=fr,en,null",
		endpoint, tmdbID, apiKey,
	)
	resp, err := httpx.Standard.Get(u)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return ""
	}
	defer resp.Body.Close()

	var out tmdbImagesResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return ""
	}
	return pickBestLogoURLFromLogos(out.Logos)
}

// FetchMediaCatalogDetails returns rich TMDB metadata for a movie/show.
// Returns nil when no API key is configured or the title can't be found.
func FetchMediaCatalogDetails(tmdbID int, mediaType models.MediaType) *models.MediaDetails {
	apiKey := tmdbAPIKey()
	if apiKey == "" || tmdbID <= 0 {
		return nil
	}
	if mediaType != models.TypeMovie && mediaType != models.TypeShow {
		return nil
	}

	cacheKey := fmt.Sprintf("%s:%d:v3", mediaType, tmdbID)
	catalogCacheMu.RLock()
	if entry, ok := catalogCache[cacheKey]; ok && time.Since(entry.stored) < catalogCacheTTL {
		catalogCacheMu.RUnlock()
		return entry.details
	}
	catalogCacheMu.RUnlock()

	endpoint := "movie"
	appendTo := "credits,images,videos,keywords,recommendations,similar"
	if mediaType == models.TypeShow {
		endpoint = "tv"
		appendTo = "aggregate_credits,images,videos,keywords,recommendations,similar"
	}

	fetch := func(lang string) *tmdbCatalogResponse {
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/%s/%d?api_key=%s&append_to_response=%s&include_image_language=fr,en,null",
			endpoint, tmdbID, apiKey, appendTo,
		)
		if lang != "" {
			u += "&language=" + lang
		}
		resp, err := httpx.Standard.Get(u)
		if err != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			return nil
		}
		defer resp.Body.Close()
		var out tmdbCatalogResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil
		}
		return &out
	}

	loc := fetch(tmdbLanguage())
	if loc == nil {
		return nil
	}
	// Fall back to English text/artwork for any localized gaps.
	if loc.Overview == "" || loc.Tagline == "" || loc.BackdropPath == "" ||
		len(loc.Images.Logos) == 0 {
		if fallback := fetch(""); fallback != nil {
			if loc.Overview == "" {
				loc.Overview = fallback.Overview
			}
			if loc.Tagline == "" {
				loc.Tagline = fallback.Tagline
			}
			if loc.BackdropPath == "" {
				loc.BackdropPath = fallback.BackdropPath
			}
			if loc.PosterPath == "" {
				loc.PosterPath = fallback.PosterPath
			}
			if len(loc.Images.Logos) == 0 && len(fallback.Images.Logos) > 0 {
				loc.Images.Logos = fallback.Images.Logos
			}
		}
	}

	details := buildCatalogDetails(loc, tmdbID, mediaType)
	if details.LogoURL == "" {
		details.LogoURL = fetchTMDBLogoURL(tmdbID, mediaType)
	}

	catalogCacheMu.Lock()
	catalogCache[cacheKey] = catalogCacheEntry{details: details, stored: time.Now()}
	catalogCacheMu.Unlock()

	return details
}

func buildCatalogDetails(r *tmdbCatalogResponse, tmdbID int, mediaType models.MediaType) *models.MediaDetails {
	d := &models.MediaDetails{
		TMDBID:           tmdbID,
		Type:             mediaType,
		Tagline:          strings.TrimSpace(r.Tagline),
		Overview:         strings.TrimSpace(r.Overview),
		BackdropURL:      backdropURLFromPath(r.BackdropPath),
		PosterURL:        posterURLFromPath(r.PosterPath),
		LogoURL:          pickBestLogoURL(r),
		Status:           strings.TrimSpace(r.Status),
		VoteAverage:      r.VoteAverage,
		Budget:           r.Budget,
		Revenue:          r.Revenue,
		OriginalLang:     r.OriginalLanguage,
		TrailerKey:       pickTrailerKey(r),
		Keywords:         pickKeywords(r),
		NumberOfSeasons:  r.NumberOfSeasons,
		NumberOfEpisodes: r.NumberOfEpisodes,
	}

	if mediaType == models.TypeShow {
		d.Title = firstNonEmpty(r.Name, r.Title)
		d.OriginalTitle = firstNonEmpty(r.OriginalName, r.OriginalTitle)
		d.ReleaseDate = r.FirstAirDate
		if len(r.EpisodeRunTime) > 0 {
			d.Runtime = r.EpisodeRunTime[0]
		}
	} else {
		d.Title = firstNonEmpty(r.Title, r.Name)
		d.OriginalTitle = firstNonEmpty(r.OriginalTitle, r.OriginalName)
		d.ReleaseDate = r.ReleaseDate
		d.Runtime = r.Runtime
	}

	for _, g := range r.Genres {
		if name := strings.TrimSpace(g.Name); name != "" {
			d.Genres = append(d.Genres, name)
		}
	}
	for _, c := range r.ProductionCompanies {
		if name := strings.TrimSpace(c.Name); name != "" {
			d.Studios = append(d.Studios, name)
		}
		if len(d.Studios) >= 4 {
			break
		}
	}
	for _, c := range r.ProductionCountries {
		if name := strings.TrimSpace(c.Name); name != "" {
			d.Countries = append(d.Countries, name)
		}
	}

	if mediaType == models.TypeShow {
		buildShowCredits(d, r)
	} else {
		buildMovieCredits(d, r)
		if r.BelongsToCollection != nil && r.BelongsToCollection.ID > 0 {
			d.Collection = &models.CollectionInfo{
				ID:          r.BelongsToCollection.ID,
				Name:        strings.TrimSpace(r.BelongsToCollection.Name),
				BackdropURL: backdropURLFromPath(r.BelongsToCollection.BackdropPath),
				PosterURL:   posterURLFromPath(r.BelongsToCollection.PosterPath),
			}
		}
	}

	d.Recommendations = mapRelatedMedia(r.Recommendations.Results, mediaType)
	d.Similar = mapRelatedMedia(r.Similar.Results, mediaType)

	return d
}

func pickTrailerKey(r *tmdbCatalogResponse) string {
	for _, v := range r.Videos.Results {
		if v.Site == "YouTube" && v.Type == "Trailer" && v.Key != "" {
			return v.Key
		}
	}
	for _, v := range r.Videos.Results {
		if v.Site == "YouTube" && v.Key != "" {
			return v.Key
		}
	}
	return ""
}

func pickKeywords(r *tmdbCatalogResponse) []string {
	out := make([]string, 0, 15)
	appendName := func(name string) {
		name = strings.TrimSpace(name)
		if name == "" || len(out) >= 15 {
			return
		}
		out = append(out, name)
	}
	for _, k := range r.Keywords.Keywords {
		appendName(k.Name)
	}
	if len(out) == 0 {
		for _, k := range r.Keywords.Results {
			appendName(k.Name)
		}
	}
	return out
}

func mapRelatedMedia(items []tmdbRelatedItem, fallbackType models.MediaType) []models.RelatedMedia {
	out := make([]models.RelatedMedia, 0, len(items))
	for _, item := range items {
		if item.ID <= 0 {
			continue
		}
		mt := fallbackType
		switch item.MediaType {
		case "tv":
			mt = models.TypeShow
		case "movie":
			mt = models.TypeMovie
		}
		title := firstNonEmpty(item.Title, item.Name)
		if title == "" {
			continue
		}
		out = append(out, models.RelatedMedia{
			ID:          item.ID,
			Type:        mt,
			Title:       title,
			PosterURL:   posterURLFromPath(item.PosterPath),
			BackdropURL: backdropURLFromPath(item.BackdropPath),
			ReleaseDate: firstNonEmpty(item.ReleaseDate, item.FirstAirDate),
			VoteAverage: item.VoteAverage,
			Overview:    item.Overview,
		})
		if len(out) >= 20 {
			break
		}
	}
	return out
}

func buildMovieCredits(d *models.MediaDetails, r *tmdbCatalogResponse) {
	for _, p := range r.Credits.Cast {
		if strings.TrimSpace(p.Name) == "" {
			continue
		}
		d.Cast = append(d.Cast, models.CatalogCastMember{
			TMDBID:     p.ID,
			Name:       p.Name,
			Character:  p.Character,
			ProfileURL: profileURLFromPath(p.ProfilePath),
		})
		if len(d.Cast) >= 30 {
			break
		}
	}
	for _, p := range r.Credits.Crew {
		switch p.Job {
		case "Director":
			if d.Director == "" {
				d.Director = p.Name
			}
		case "Screenplay", "Writer", "Story":
			if len(d.Writers) < 3 && !contains(d.Writers, p.Name) {
				d.Writers = append(d.Writers, p.Name)
			}
		case "Editor":
			if len(d.Editors) < 2 && !contains(d.Editors, p.Name) {
				d.Editors = append(d.Editors, p.Name)
			}
		}
	}
}

func buildShowCredits(d *models.MediaDetails, r *tmdbCatalogResponse) {
	for _, p := range r.AggregateCredits.Cast {
		if strings.TrimSpace(p.Name) == "" {
			continue
		}
		character := ""
		if len(p.Roles) > 0 {
			character = p.Roles[0].Character
		}
		d.Cast = append(d.Cast, models.CatalogCastMember{
			TMDBID:     p.ID,
			Name:       p.Name,
			Character:  character,
			ProfileURL: profileURLFromPath(p.ProfilePath),
		})
		if len(d.Cast) >= 30 {
			break
		}
	}
	for _, p := range r.AggregateCredits.Crew {
		for _, j := range p.Jobs {
			switch j.Job {
			case "Director", "Creator", "Executive Producer":
				if d.Director == "" {
					d.Director = p.Name
				}
			case "Writer", "Screenplay", "Story":
				if len(d.Writers) < 3 && !contains(d.Writers, p.Name) {
					d.Writers = append(d.Writers, p.Name)
				}
			case "Editor":
				if len(d.Editors) < 2 && !contains(d.Editors, p.Name) {
					d.Editors = append(d.Editors, p.Name)
				}
			}
		}
	}
}

// ---- Person (actor) details ----

type tmdbCreditItem struct {
	ID           int    `json:"id"`
	Title        string `json:"title"`
	Name         string `json:"name"`
	PosterPath   string `json:"poster_path"`
	BackdropPath string `json:"backdrop_path"`
	ReleaseDate  string `json:"release_date"`
	FirstAirDate string `json:"first_air_date"`
	MediaType    string  `json:"media_type"`
	Character    string  `json:"character"`
	VoteAverage  float64 `json:"vote_average"`
}

type tmdbPersonResponse struct {
	ID                 int    `json:"id"`
	Name               string `json:"name"`
	Biography          string `json:"biography"`
	Birthday           string `json:"birthday"`
	Deathday           string `json:"deathday"`
	PlaceOfBirth       string `json:"place_of_birth"`
	KnownForDepartment string `json:"known_for_department"`
	ProfilePath        string `json:"profile_path"`
	CombinedCredits    struct {
		Cast []tmdbCreditItem `json:"cast"`
	} `json:"combined_credits"`
}

// FetchPersonDetails returns an actor/crew profile with filmography, or nil.
func FetchPersonDetails(personID int) *models.PersonDetails {
	apiKey := tmdbAPIKey()
	if apiKey == "" || personID <= 0 {
		return nil
	}

	fetch := func(lang string) *tmdbPersonResponse {
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/person/%d?api_key=%s&append_to_response=combined_credits",
			personID, apiKey,
		)
		if lang != "" {
			u += "&language=" + lang
		}
		resp, err := httpx.Standard.Get(u)
		if err != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			return nil
		}
		defer resp.Body.Close()
		var out tmdbPersonResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil
		}
		return &out
	}

	loc := fetch(tmdbLanguage())
	if loc == nil {
		return nil
	}
	if loc.Biography == "" {
		if fallback := fetch(""); fallback != nil && fallback.Biography != "" {
			loc.Biography = fallback.Biography
		}
	}

	d := &models.PersonDetails{
		ID:                 personID,
		Name:               strings.TrimSpace(loc.Name),
		ProfileURL:         profileH632FromPath(loc.ProfilePath),
		Biography:          strings.TrimSpace(loc.Biography),
		Birthday:           loc.Birthday,
		Deathday:           loc.Deathday,
		PlaceOfBirth:       strings.TrimSpace(loc.PlaceOfBirth),
		KnownForDepartment: strings.TrimSpace(loc.KnownForDepartment),
	}

	credits := loc.CombinedCredits.Cast
	// Keep entries with artwork, most recent first.
	filtered := credits[:0]
	for _, c := range credits {
		if c.PosterPath != "" {
			filtered = append(filtered, c)
		}
	}
	sortCreditsByDateDesc(filtered)

	if len(filtered) > 0 {
		d.BackdropURL = backdropURLFromPath(filtered[0].BackdropPath)
	}
	for i, c := range filtered {
		if i >= 50 {
			break
		}
		mediaType := "movie"
		if c.MediaType == "tv" {
			mediaType = string(models.TypeShow)
		}
		date := c.ReleaseDate
		if date == "" {
			date = c.FirstAirDate
		}
		d.Filmography = append(d.Filmography, models.CatalogItem{
			TMDBID:    c.ID,
			Title:     firstNonEmpty(c.Title, c.Name),
			PosterURL: posterURLFromPath(c.PosterPath),
			Year:      yearFromDate(date),
			MediaType: mediaType,
			Character: strings.TrimSpace(c.Character),
			Rating:    c.VoteAverage,
		})
	}

	return d
}

// ---- Collection (saga) details ----

type tmdbCollectionResponse struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	Overview     string `json:"overview"`
	BackdropPath string `json:"backdrop_path"`
	Parts        []struct {
		ID          int     `json:"id"`
		Title       string  `json:"title"`
		Name        string  `json:"name"`
		PosterPath  string  `json:"poster_path"`
		ReleaseDate string  `json:"release_date"`
		VoteAverage float64 `json:"vote_average"`
	} `json:"parts"`
}

// FetchCollectionDetails returns a movie saga with its ordered parts, or nil.
func FetchCollectionDetails(collectionID int) *models.CollectionDetails {
	apiKey := tmdbAPIKey()
	if apiKey == "" || collectionID <= 0 {
		return nil
	}

	fetch := func(lang string) *tmdbCollectionResponse {
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/collection/%d?api_key=%s",
			collectionID, apiKey,
		)
		if lang != "" {
			u += "&language=" + lang
		}
		resp, err := httpx.Standard.Get(u)
		if err != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			return nil
		}
		defer resp.Body.Close()
		var out tmdbCollectionResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil
		}
		return &out
	}

	loc := fetch(tmdbLanguage())
	if loc == nil {
		return nil
	}
	if loc.Overview == "" {
		if fallback := fetch(""); fallback != nil && fallback.Overview != "" {
			loc.Overview = fallback.Overview
		}
	}

	d := &models.CollectionDetails{
		ID:          loc.ID,
		Name:        strings.TrimSpace(loc.Name),
		Overview:    strings.TrimSpace(loc.Overview),
		BackdropURL: backdropURLFromPath(loc.BackdropPath),
	}
	for _, p := range loc.Parts {
		d.Parts = append(d.Parts, models.CatalogItem{
			TMDBID:    p.ID,
			Title:     firstNonEmpty(p.Title, p.Name),
			PosterURL: posterURLFromPath(p.PosterPath),
			Year:      yearFromDate(p.ReleaseDate),
			MediaType: string(models.TypeMovie),
			Rating:    p.VoteAverage,
		})
	}
	return d
}

func profileH632FromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/h632" + path
}

func yearFromDate(date string) string {
	if len(date) >= 4 {
		return date[:4]
	}
	return ""
}

// sortCreditsByDateDesc orders credits newest-first by release/air date.
func sortCreditsByDateDesc(items []tmdbCreditItem) {
	sort.SliceStable(items, func(i, j int) bool {
		di := items[i].ReleaseDate
		if di == "" {
			di = items[i].FirstAirDate
		}
		dj := items[j].ReleaseDate
		if dj == "" {
			dj = items[j].FirstAirDate
		}
		return di > dj
	})
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if s := strings.TrimSpace(v); s != "" {
			return s
		}
	}
	return ""
}

func contains(list []string, v string) bool {
	for _, item := range list {
		if item == v {
			return true
		}
	}
	return false
}
