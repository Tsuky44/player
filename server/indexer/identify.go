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
	"time"

	"project-player/server/models"
)

// Minimum TMDB search score to accept an automatic match (Emby-like: refuse weak guesses).
// Exact title = 1.0; exact+year ≈ 1.6; substring+year ≈ 1.45; weak Jaccard stays well below.
const minTMDBAcceptScore = 0.95

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
	return identifyFromHints(hints, models.TypeMovie)
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
	client := &http.Client{Timeout: 12 * time.Second}

	trySearch := func(query, searchYear, lang string) []tmdbSearchResult {
		if query == "" {
			return nil
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
		resp, err := client.Get(u)
		if err != nil {
			return nil
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil
		}
		var out TMDBResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil
		}
		results := make([]tmdbSearchResult, 0, len(out.Results))
		for _, r := range out.Results {
			results = append(results, tmdbSearchResult{
				ID: r.ID, Title: r.Title, Name: r.Name, Overview: r.Overview,
				PosterPath: r.PosterPath, ReleaseDate: r.ReleaseDate, FirstAirDate: r.FirstAirDate,
			})
		}
		return results
	}

	yearStr := ""
	if parsed.Year > 0 {
		yearStr = strconv.Itoa(parsed.Year)
	}

	var best tmdbSearchResult
	bestScore := -1.0
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

// isConfidentTMDBMatch mirrors Emby's refusal to lock a vague popularity hit.
func isConfidentTMDBMatch(r tmdbSearchResult, targetTitle string, targetYear int, mediaType models.MediaType, score float64) bool {
	if r.ID == 0 || score < minTMDBAcceptScore {
		return false
	}
	target := normalizeForMatch(targetTitle)
	titleScore := 0.0
	for _, cand := range []string{r.Title, r.Name} {
		if s := titleSimilarity(target, normalizeForMatch(cand)); s > titleScore {
			titleScore = s
		}
	}
	if titleScore < 0.7 {
		return false
	}
	if targetYear > 0 {
		ry := tmdbResultYear(r, mediaType)
		if ry > 0 && absInt(ry-targetYear) > 1 {
			return false
		}
		// With a known year, require a strong title signal (substring/exact).
		if titleScore < 0.85 {
			return false
		}
	}
	return true
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
	resp, err := http.Get(u)
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

// resolveShowFolderPath returns the on-disk show folder for NFO lookup.
func resolveShowFolderPath(seriesRoot string, relParts []string) string {
	if seriesRoot == "" || len(relParts) == 0 {
		return ""
	}
	for i := 0; i < len(relParts)-1; i++ {
		part := strings.TrimSpace(relParts[i])
		if part == "" || looksLikeEpisodeReleaseFolder(part) {
			continue
		}
		lower := strings.ToLower(part)
		if strings.HasPrefix(lower, "season ") || strings.HasPrefix(lower, "saison ") {
			continue
		}
		return filepath.Join(append([]string{seriesRoot}, relParts[:i+1]...)...)
	}
	return ""
}
