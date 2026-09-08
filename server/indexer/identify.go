package indexer

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/httpx"
	"project-player/server/models"
)

// Title-similarity gates for accepting an automatic match (Emby-like: refuse
// weak guesses, but don't leave a whole library unidentified either).
const (
	// With a matching release year the title only has to be close.
	minTitleScoreWithYear = 0.80
	// Without a year, only a near-identical title is trustworthy.
	minTitleScoreNoYear = 0.92
)

// IdentityMatch is the result of Emby-style media identification.
type IdentityMatch struct {
	TMDBID      int
	IMDbID      string
	Title       string
	Overview    string
	PosterURL   string
	ReleaseDate string
	Confidence  float64
	Source      string // path_id | nfo | imdb_find | tmdb_search | none
	Matched     bool
}

// IdentifyMovie resolves a movie file using local IDs/NFO first, then scored TMDB search.
func IdentifyMovie(videoPath, moviesRoot string) IdentityMatch {
	hints := CollectMovieLocalIdentity(videoPath, moviesRoot)
	match := identifyFromHints(hints, models.TypeMovie)
	if match.Matched || hints.TMDBID > 0 || hints.IMDbID != "" || hints.Source == "nfo" {
		return match
	}
	// A download folder can carry a different name. Try the actual release
	// filename when the folder search failed, keeping the same confidence gates.
	base := strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath))
	parsed := ParseReleaseFilename(StripProviderIDs(base), models.TypeMovie)
	if !looksLikeGenericVideoName(base) && parsed.Title != "" && parsed.Title != hints.Title {
		fallback := identifyFromHints(LocalIdentityHints{Title: parsed.Title, Year: parsed.Year, Source: "filename"}, models.TypeMovie)
		if fallback.Matched {
			return fallback
		}
	}
	return match
}

// IdentifyShow resolves a series from folder/name hints using the same Emby priority order.
func IdentifyShow(showFolderPath, rawSearchKey string) IdentityMatch {
	hints := CollectShowLocalIdentity(showFolderPath, rawSearchKey)
	return identifyFromHints(hints, models.TypeShow)
}

// IdentifyFromRawName is used when only a release/folder string is available (backfill/rematch).
func IdentifyFromRawName(rawName string, mediaType models.MediaType) IdentityMatch {
	cleaned := StripProviderIDs(rawName)
	tmdbID, imdbID, tvdbID := ExtractProviderIDs(rawName)
	parsed := ParseReleaseFilename(cleaned, mediaType)
	hints := LocalIdentityHints{
		TMDBID: tmdbID,
		IMDbID: imdbID,
		TVDBID: tvdbID,
		Title:  parsed.Title,
		Year:   parsed.Year,
		Source: "filename",
	}
	if tmdbID > 0 || imdbID != "" {
		hints.Source = "path_id"
	}
	if hints.Title == "" {
		hints.Title = cleaned
	}
	return identifyFromHints(hints, mediaType)
}

func identifyFromHints(hints LocalIdentityHints, mediaType models.MediaType) IdentityMatch {
	fallbackTitle := strings.TrimSpace(hints.Title)
	if fallbackTitle == "" {
		fallbackTitle = "Unknown"
	}

	// 1) Explicit TMDB id (path tag or NFO) — certain.
	if hints.TMDBID > 0 {
		poster, overview, date, title := fetchTMDBDetailsByID(hints.TMDBID, mediaType)
		if title == "" {
			title = fallbackTitle
		}
		return IdentityMatch{
			TMDBID:      hints.TMDBID,
			IMDbID:      hints.IMDbID,
			Title:       title,
			Overview:    overview,
			PosterURL:   poster,
			ReleaseDate: date,
			Confidence:  1.0,
			Source:      hints.Source,
			Matched:     true,
		}
	}

	// 2) IMDb id → TMDB /find (Emby external id path).
	if hints.IMDbID != "" {
		if id := findTMDBIDByExternal(hints.IMDbID, "imdb_id", mediaType); id > 0 {
			poster, overview, date, title := fetchTMDBDetailsByID(id, mediaType)
			if title == "" {
				title = fallbackTitle
			}
			return IdentityMatch{
				TMDBID:      id,
				IMDbID:      hints.IMDbID,
				Title:       title,
				Overview:    overview,
				PosterURL:   poster,
				ReleaseDate: date,
				Confidence:  1.0,
				Source:      "imdb_find",
				Matched:     true,
			}
		}
	}

	// TVDB IDs from series NFO/path tags are also authoritative local signals.
	if mediaType == models.TypeShow && hints.TVDBID > 0 {
		if id := findTMDBIDByExternal(strconv.Itoa(hints.TVDBID), "tvdb_id", mediaType); id > 0 {
			poster, overview, date, title := fetchTMDBDetailsByID(id, mediaType)
			if title == "" {
				title = fallbackTitle
			}
			return IdentityMatch{TMDBID: id, IMDbID: hints.IMDbID, Title: title,
				Overview: overview, PosterURL: poster, ReleaseDate: date,
				Confidence: 1, Source: "tvdb_find", Matched: true}
		}
	}

	// 3) Scored TMDB search — only accept confident matches.
	searchRaw := fallbackTitle
	if hints.Year > 0 && !strings.Contains(searchRaw, strconv.Itoa(hints.Year)) {
		searchRaw = fmt.Sprintf("%s %d", searchRaw, hints.Year)
	}
	match := searchTMDBWithConfidence(searchRaw, hints.Year, mediaType)
	if match.Matched {
		if match.IMDbID == "" {
			match.IMDbID = hints.IMDbID
		}
		return match
	}

	log.Printf("Identify: no confident match for %q (%s) — indexing without tmdb_id", fallbackTitle, mediaType)
	return IdentityMatch{
		IMDbID:     hints.IMDbID,
		Title:      fallbackTitle,
		Confidence: match.Confidence,
		Source:     "none",
		Matched:    false,
	}
}

func searchTMDBWithConfidence(rawTitle string, hintYear int, mediaType models.MediaType) IdentityMatch {
	apiKey := tmdbAPIKey()
	if apiKey == "" || strings.TrimSpace(rawTitle) == "" {
		return IdentityMatch{Source: "none"}
	}

	parsed := ParseReleaseFilename(rawTitle, mediaType)
	if hintYear > 0 && parsed.Year == 0 {
		parsed.Year = hintYear
	}
	if parsed.Title == "" {
		parsed.Title = strings.TrimSpace(rawTitle)
	}
	queries := BuildTMDBSearchQueries(parsed)

	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}

	trySearch := func(query, searchYear, lang string) []tmdbSearchResult {
		if query == "" {
			return nil
		}
		cacheKey := strings.Join([]string{endpoint, query, searchYear, lang}, "|")
		if cached, ok := getCachedSearch(cacheKey); ok {
			return cached
		}
		u := fmt.Sprintf(
			"https://api.themoviedb.org/3/search/%s?api_key=%s&query=%s",
			endpoint, apiKey, url.QueryEscape(query),
		)
		if lang != "" {
			u += "&language=" + lang
		}
		if searchYear != "" {
			if mediaType == models.TypeShow {
				u += "&first_air_date_year=" + searchYear
			} else {
				u += "&year=" + searchYear
			}
		}

		var out TMDBResponse
		ok := false
		// One retry: a transient network error must not silently leave a film
		// unidentified for good.
		for attempt := 0; attempt < 2; attempt++ {
			if attempt > 0 {
				time.Sleep(600 * time.Millisecond)
			}
			resp, err := httpx.Standard.Get(u)
			if err != nil {
				continue
			}
			if resp.StatusCode == http.StatusTooManyRequests {
				resp.Body.Close()
				time.Sleep(1500 * time.Millisecond)
				continue
			}
			if resp.StatusCode != http.StatusOK {
				resp.Body.Close()
				break
			}
			err = json.NewDecoder(resp.Body).Decode(&out)
			resp.Body.Close()
			if err == nil {
				ok = true
				break
			}
		}
		if !ok {
			return nil
		}

		results := make([]tmdbSearchResult, 0, len(out.Results))
		for _, r := range out.Results {
			results = append(results, tmdbSearchResult{
				ID: r.ID, Title: r.Title, Name: r.Name,
				OriginalTitle: r.OriginalTitle, OriginalName: r.OriginalName,
				Overview:   r.Overview,
				PosterPath: r.PosterPath, ReleaseDate: r.ReleaseDate, FirstAirDate: r.FirstAirDate,
				Popularity: r.Popularity,
			})
		}
		putCachedSearch(cacheKey, results)
		return results
	}

	yearStr := ""
	if parsed.Year > 0 {
		yearStr = strconv.Itoa(parsed.Year)
	}

	var best tmdbSearchResult
	bestScore := -1.0
search:
	for _, query := range queries {
		for _, searchYear := range []string{yearStr, ""} {
			for _, lang := range []string{tmdbLanguage(), ""} {
				results := trySearch(query, searchYear, lang)
				if len(results) == 0 {
					continue
				}
				candidate := pickBestTMDBResult(results, parsed.Title, parsed.Year, mediaType)
				score := scoreTMDBResult(candidate, parsed.Title, parsed.Year, mediaType)
				if score > bestScore {
					best = candidate
					bestScore = score
				}
				// Exact title on the right year: no better match exists, stop
				// burning API calls on the remaining query variants.
				if bestTitleScore(best, parsed.Title) >= 1.0 &&
					(parsed.Year == 0 || absInt(tmdbResultYear(best, mediaType)-parsed.Year) <= 1) {
					break search
				}
			}
		}
	}

	if best.ID == 0 || !isConfidentTMDBMatch(best, parsed.Title, parsed.Year, mediaType, bestScore) {
		if best.ID != 0 {
			log.Printf("Identify: rejected weak TMDB candidate id=%d score=%.2f for %q", best.ID, bestScore, parsed.Title)
		}
		return IdentityMatch{Title: parsed.Title, Confidence: bestScore, Source: "none", Matched: false}
	}

	poster, overview, date, title := fetchTMDBDetailsByID(best.ID, mediaType)
	if poster == "" {
		poster = posterURLFromPath(best.PosterPath)
	}
	if overview == "" {
		overview = best.Overview
	}
	if title == "" {
		title = tmdbDisplayTitle(best.Title, best.Name, mediaType)
	}
	if date == "" {
		if mediaType == models.TypeShow {
			date = best.FirstAirDate
		} else {
			date = best.ReleaseDate
		}
	}

	return IdentityMatch{
		TMDBID:      best.ID,
		Title:       title,
		Overview:    overview,
		PosterURL:   poster,
		ReleaseDate: date,
		Confidence:  bestScore,
		Source:      "tmdb_search",
		Matched:     true,
	}
}

// isConfidentTMDBMatch mirrors Emby's refusal to lock a vague popularity hit:
// the title must really match, and a known year must not contradict the result.
func isConfidentTMDBMatch(r tmdbSearchResult, targetTitle string, targetYear int, mediaType models.MediaType, _ float64) bool {
	if r.ID == 0 {
		return false
	}
	titleScore := bestTitleScore(r, targetTitle)
	resultYear := tmdbResultYear(r, mediaType)

	if targetYear > 0 && resultYear > 0 {
		// A different year means a different film, however popular the candidate.
		if absInt(resultYear-targetYear) > 1 {
			return false
		}
		return titleScore >= minTitleScoreWithYear
	}
	return titleScore >= minTitleScoreNoYear
}

// Search results are cached for the length of a scan: the same show/collection
// is looked up over and over (per episode, then again during backfill).
var (
	searchCache   = map[string][]tmdbSearchResult{}
	searchCacheMu sync.Mutex
)

func getCachedSearch(key string) ([]tmdbSearchResult, bool) {
	searchCacheMu.Lock()
	defer searchCacheMu.Unlock()
	results, ok := searchCache[key]
	return results, ok
}

func putCachedSearch(key string, results []tmdbSearchResult) {
	searchCacheMu.Lock()
	defer searchCacheMu.Unlock()
	if len(searchCache) > 5000 {
		searchCache = map[string][]tmdbSearchResult{}
	}
	searchCache[key] = results
}

// ResetSearchCache drops memoized TMDB search results (called when a scan starts).
func ResetSearchCache() {
	searchCacheMu.Lock()
	searchCache = map[string][]tmdbSearchResult{}
	searchCacheMu.Unlock()
}

func findTMDBIDByExternal(externalID, source string, mediaType models.MediaType) int {
	apiKey := tmdbAPIKey()
	if apiKey == "" || strings.TrimSpace(externalID) == "" {
		return 0
	}
	u := fmt.Sprintf(
		"https://api.themoviedb.org/3/find/%s?api_key=%s&external_source=%s",
		url.PathEscape(externalID), apiKey, url.QueryEscape(source),
	)
	resp, err := httpx.Standard.Get(u)
	if err != nil {
		log.Printf("TMDB find: %v", err)
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0
	}

	var out struct {
		MovieResults []struct {
			ID int `json:"id"`
		} `json:"movie_results"`
		TVResults []struct {
			ID int `json:"id"`
		} `json:"tv_results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0
	}
	if mediaType == models.TypeShow {
		if len(out.TVResults) > 0 {
			return out.TVResults[0].ID
		}
		return 0
	}
	if len(out.MovieResults) > 0 {
		return out.MovieResults[0].ID
	}
	return 0
}

// resolveShowFolderPath returns the on-disk show folder for NFO lookup. Like the
// title resolution it walks from the deepest folder up, so a nested library
// points at the series folder and not at its category folder.
func resolveShowFolderPath(seriesRoot string, relParts []string) string {
	if seriesRoot == "" || len(relParts) == 0 {
		return ""
	}
	for i := len(relParts) - 2; i >= 0; i-- {
		part := strings.TrimSpace(relParts[i])
		if part == "" || looksLikeEpisodeReleaseFolder(part) || looksLikeSeasonFolderName(part) {
			continue
		}
		if looksLikeCategoryFolderName(part) {
			continue
		}
		return filepath.Join(append([]string{seriesRoot}, relParts[:i+1]...)...)
	}
	return ""
}
