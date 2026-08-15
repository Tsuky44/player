package indexer

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/models"
)

// backfilling is read by the scan-status endpoint while the backfill goroutine
// writes it — see the note on indexer.scanning.
var backfilling atomic.Bool

// IsBackfilling reports whether a metadata backfill is currently running.
func IsBackfilling() bool { return backfilling.Load() }

type tmdbDetails struct {
	ID            int    `json:"id"`
	Title         string `json:"title"`
	Name          string `json:"name"`
	OriginalTitle string `json:"original_title"`
	OriginalName  string `json:"original_name"`
	Overview      string `json:"overview"`
	PosterPath    string `json:"poster_path"`
	ReleaseDate   string `json:"release_date"`
	FirstAirDate  string `json:"first_air_date"`
}

type tmdbTranslationsResponse struct {
	Translations []struct {
		ISO6391 string `json:"iso_639_1"`
		Data    struct {
			Title    string `json:"title"`
			Name     string `json:"name"`
			Overview string `json:"overview"`
		} `json:"data"`
	} `json:"translations"`
}

func tmdbAPIKey() string {
	return config.TMDBAPIKey()
}

// tmdbLanguage returns the TMDB API language (default fr-FR).
func tmdbLanguage() string {
	return config.TMDBLanguage()
}

func tmdbTranslationISO639() string {
	lang := tmdbLanguage()
	if idx := strings.Index(lang, "-"); idx > 0 {
		return strings.ToLower(lang[:idx])
	}
	return strings.ToLower(lang)
}

func posterURLFromPath(path string) string {
	if path == "" {
		return ""
	}
	return "https://image.tmdb.org/t/p/w500" + path
}

// humanizeFilenameTitle turns a release filename into a readable local title.
func humanizeFilenameTitle(raw string) string {
	return ReleaseDisplayTitle(raw, models.TypeMovie)
}

type tmdbSearchResult struct {
	ID            int
	Title         string
	Name          string
	OriginalTitle string
	OriginalName  string
	Overview      string
	PosterPath    string
	ReleaseDate   string
	FirstAirDate  string
	Popularity    float64
}

// candidateTitles lists every name a result can be matched against. Comparing
// the original title too is what makes an English release name match a French
// TMDB entry (and the reverse).
func (r tmdbSearchResult) candidateTitles() []string {
	return []string{r.Title, r.Name, r.OriginalTitle, r.OriginalName}
}

func tmdbResultYear(r tmdbSearchResult, mediaType models.MediaType) int {
	date := r.ReleaseDate
	if mediaType == models.TypeShow {
		date = r.FirstAirDate
	}
	if len(date) >= 4 {
		if y, err := strconv.Atoi(date[:4]); err == nil {
			return y
		}
	}
	return 0
}

// pickBestTMDBResult chooses the result that best matches the parsed title and
// year, rather than blindly trusting TMDB's popularity ordering. This fixes
// mis-identified titles where a more popular but unrelated film ranked first.
func pickBestTMDBResult(results []tmdbSearchResult, targetTitle string, targetYear int, mediaType models.MediaType) tmdbSearchResult {
	if len(results) == 0 {
		return tmdbSearchResult{}
	}
	if targetYear > 0 {
		var filtered []tmdbSearchResult
		for _, r := range results {
			ry := tmdbResultYear(r, mediaType)
			if ry == 0 || absInt(ry-targetYear) <= 1 {
				filtered = append(filtered, r)
			}
		}
		if len(filtered) > 0 {
			results = filtered
		}
	}
	best := results[0]
	bestScore := scoreTMDBResult(best, targetTitle, targetYear, mediaType)
	for _, r := range results[1:] {
		// Strictly-greater keeps TMDB's popularity order as the tie-breaker.
		if s := scoreTMDBResult(r, targetTitle, targetYear, mediaType); s > bestScore {
			best = r
			bestScore = s
		}
	}
	return best
}

// bestTitleScore returns how well a candidate's names match the parsed title.
func bestTitleScore(r tmdbSearchResult, targetTitle string) float64 {
	target := normalizeForMatch(targetTitle)
	titleScore := 0.0
	for _, cand := range r.candidateTitles() {
		if s := titleSimilarity(target, normalizeForMatch(cand)); s > titleScore {
			titleScore = s
		}
	}
	return titleScore
}

// scoreTMDBResult ranks a candidate by title similarity (dominant signal) and
// release-year proximity.
func scoreTMDBResult(r tmdbSearchResult, targetTitle string, targetYear int, mediaType models.MediaType) float64 {
	score := bestTitleScore(r, targetTitle)
	if targetYear > 0 {
		if ry := tmdbResultYear(r, mediaType); ry > 0 {
			switch diff := absInt(ry - targetYear); {
			case diff == 0:
				score += 0.6
			case diff == 1:
				score += 0.25
			default:
				score -= 0.4
			}
		}
	}
	// Tiny popularity nudge, capped well below any title/year signal: it only
	// separates candidates that are otherwise equally good across search variants.
	if r.Popularity > 0 {
		nudge := r.Popularity / 1000
		if nudge > 0.02 {
			nudge = 0.02
		}
		score += nudge
	}
	return score
}

// titleSimilarity returns a 0..1 score between two already-normalized titles.
func titleSimilarity(a, b string) float64 {
	if a == "" || b == "" {
		return 0
	}
	if a == b {
		return 1.0
	}

	best := 0.0
	// Containment scaled by length: "alien" inside "aliens" is a near match,
	// "alien" inside "alien vs predator" is not.
	if strings.Contains(a, b) || strings.Contains(b, a) {
		shorter, longer := len(a), len(b)
		if shorter > longer {
			shorter, longer = longer, shorter
		}
		best = 0.55 + 0.4*float64(shorter)/float64(longer)
	}

	// Token overlap (Dice) catches reordered or partially translated titles.
	if s := tokenDiceScore(a, b); s > best {
		best = s
	}
	// Edit distance catches accents, punctuation and small typos.
	if s := editDistanceScore(a, b); s > best {
		best = s
	}
	return best
}

func tokenDiceScore(a, b string) float64 {
	wordsA := strings.Fields(a)
	wordsB := strings.Fields(b)
	if len(wordsA) == 0 || len(wordsB) == 0 {
		return 0
	}
	countB := map[string]int{}
	for _, w := range wordsB {
		countB[w]++
	}
	common := 0
	for _, w := range wordsA {
		if countB[w] > 0 {
			countB[w]--
			common++
		}
	}
	return 0.9 * 2 * float64(common) / float64(len(wordsA)+len(wordsB))
}

// editDistanceScore is 1 - normalized Levenshtein distance, capped just under an
// exact match so only identical titles ever score 1.0.
func editDistanceScore(a, b string) float64 {
	maxLen := len(a)
	if len(b) > maxLen {
		maxLen = len(b)
	}
	if maxLen == 0 {
		return 0
	}
	dist := levenshtein(a, b)
	score := 1 - float64(dist)/float64(maxLen)
	if score > 0.98 {
		score = 0.98
	}
	if score < 0 {
		return 0
	}
	return score
}

func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min(min(cur[j-1]+1, prev[j]+1), prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}

// normalizeForMatch lowercases, strips accents and punctuation, and collapses
// whitespace so titles can be compared reliably.
func normalizeForMatch(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = stripDiacritics(s)
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteRune(' ')
		}
	}
	return strings.TrimSpace(spaceRe.ReplaceAllString(b.String(), " "))
}

var diacriticFolds = map[rune]rune{
	'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
	'ç': 'c',
	'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
	'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
	'ñ': 'n',
	'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o',
	'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
	'ý': 'y', 'ÿ': 'y',
}

func stripDiacritics(s string) string {
	var b strings.Builder
	for _, r := range s {
		if folded, ok := diacriticFolds[r]; ok {
			b.WriteRune(folded)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func tmdbDisplayTitle(title, name string, mediaType models.MediaType) string {
	if mediaType == models.TypeShow && name != "" {
		return name
	}
	if title != "" {
		return title
	}
	return name
}

func tmdbOriginalTitle(d tmdbDetails, mediaType models.MediaType) string {
	if mediaType == models.TypeShow {
		return d.OriginalName
	}
	return d.OriginalTitle
}

func localizedTitleNeedsTranslation(displayTitle, originalTitle string) bool {
	displayTitle = strings.TrimSpace(displayTitle)
	if displayTitle == "" {
		return true
	}
	originalTitle = strings.TrimSpace(originalTitle)
	if originalTitle == "" {
		return false
	}
	return strings.EqualFold(displayTitle, originalTitle)
}

func fetchTMDBTranslation(tmdbID int, mediaType models.MediaType) (title, overview string) {
	apiKey := tmdbAPIKey()
	if apiKey == "" || tmdbID <= 0 {
		return "", ""
	}

	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}

	u := fmt.Sprintf(
		"https://api.themoviedb.org/3/%s/%d/translations?api_key=%s",
		endpoint, tmdbID, apiKey,
	)
	resp, err := httpx.Standard.Get(u)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return "", ""
	}
	defer resp.Body.Close()

	var out tmdbTranslationsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", ""
	}

	wantLang := tmdbTranslationISO639()
	for _, tr := range out.Translations {
		if !strings.EqualFold(tr.ISO6391, wantLang) {
			continue
		}
		if mediaType == models.TypeShow {
			return strings.TrimSpace(tr.Data.Name), strings.TrimSpace(tr.Data.Overview)
		}
		return strings.TrimSpace(tr.Data.Title), strings.TrimSpace(tr.Data.Overview)
	}
	return "", ""
}

// fetchTMDBMetadata queries TMDB with Emby-style confidence gating.
// Weak popularity hits are rejected (tmdbID stays 0) so the library is not poisoned.
func fetchTMDBMetadata(title string, mediaType models.MediaType) (posterURL string, overview string, releaseDate string, tmdbID int, displayTitle string) {
	identity := IdentifyFromRawName(title, mediaType)
	displayTitle = identity.Title
	if !identity.Matched {
		return "", "", "", 0, displayTitle
	}
	return identity.PosterURL, identity.Overview, identity.ReleaseDate, identity.TMDBID, identity.Title
}

func fetchTMDBDetailsByID(tmdbID int, mediaType models.MediaType) (posterURL, overview, releaseDate, displayTitle string) {
	apiKey := tmdbAPIKey()
	if apiKey == "" || tmdbID <= 0 {
		return "", "", "", ""
	}

	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}

	fetch := func(lang string) tmdbDetails {
		u := fmt.Sprintf("https://api.themoviedb.org/3/%s/%d?api_key=%s", endpoint, tmdbID, apiKey)
		if lang != "" {
			u += "&language=" + lang
		}
		resp, err := httpx.Standard.Get(u)
		if err != nil || resp.StatusCode != http.StatusOK {
			if resp != nil {
				resp.Body.Close()
			}
			return tmdbDetails{}
		}
		defer resp.Body.Close()
		var d tmdbDetails
		_ = json.NewDecoder(resp.Body).Decode(&d)
		return d
	}

	// Keep localized title/overview; only fall back to English for missing artwork/text.
	loc := fetch(tmdbLanguage())
	fallback := tmdbDetails{}
	if loc.PosterPath == "" || loc.Overview == "" {
		fallback = fetch("")
	}

	posterPath := loc.PosterPath
	if posterPath == "" {
		posterPath = fallback.PosterPath
	}
	posterURL = posterURLFromPath(posterPath)

	overview = strings.TrimSpace(loc.Overview)
	if overview == "" {
		overview = strings.TrimSpace(fallback.Overview)
	}

	displayTitle = tmdbDisplayTitle(loc.Title, loc.Name, mediaType)
	originalTitle := tmdbOriginalTitle(loc, mediaType)
	if originalTitle == "" {
		originalTitle = tmdbOriginalTitle(fallback, mediaType)
	}
	if localizedTitleNeedsTranslation(displayTitle, originalTitle) {
		if trTitle, trOverview := fetchTMDBTranslation(tmdbID, mediaType); trTitle != "" {
			displayTitle = trTitle
			if trOverview != "" {
				overview = trOverview
			}
		} else if displayTitle == "" {
			displayTitle = tmdbDisplayTitle(fallback.Title, fallback.Name, mediaType)
		}
	}

	if mediaType == models.TypeShow {
		releaseDate = loc.FirstAirDate
		if releaseDate == "" {
			releaseDate = fallback.FirstAirDate
		}
	} else {
		releaseDate = loc.ReleaseDate
		if releaseDate == "" {
			releaseDate = fallback.ReleaseDate
		}
	}
	return posterURL, overview, releaseDate, displayTitle
}

func enrichSearchTitle(storedTitle, filePath string, mediaType models.MediaType, mediaID int) string {
	if filePath != "" {
		if mediaType == models.TypeMovie {
			// Same folder-vs-filename rule as the scanner, so a film in its own
			// folder is searched by folder and one in a genre folder by filename.
			if name := ResolveMovieLookupName(filePath, filepath.Dir(filepath.Dir(filePath))); name != "" {
				return name
			}
		}
		base := strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath))
		if base != "" {
			return base
		}
	}
	if mediaType == models.TypeShow && mediaID > 0 {
		if raw := sampleShowReleaseName(mediaID); raw != "" {
			return raw
		}
	}
	return storedTitle
}

func sampleShowReleaseName(showID int) string {
	folder, epFile := ShowLocalLibraryHint(showID)
	if folder != "" {
		return folder
	}
	return epFile
}

func enrichMediaRecord(id int, title string, mediaType models.MediaType, existingTMDBID int) bool {
	var posterURL, overview, releaseDate, displayTitle string
	var tmdbID int

	if existingTMDBID > 0 {
		var detailTitle string
		posterURL, overview, releaseDate, detailTitle = fetchTMDBDetailsByID(existingTMDBID, mediaType)
		tmdbID = existingTMDBID
		displayTitle = detailTitle
	}

	if posterURL == "" || overview == "" || displayTitle == "" {
		var searchedOverview, searchedDate, searchedTitle string
		var searchedPoster string
		var searchedID int
		searchedPoster, searchedOverview, searchedDate, searchedID, searchedTitle = fetchTMDBMetadata(title, mediaType)
		if posterURL == "" {
			posterURL = searchedPoster
		}
		if overview == "" {
			overview = searchedOverview
		}
		if releaseDate == "" {
			releaseDate = searchedDate
		}
		if tmdbID == 0 {
			tmdbID = searchedID
		}
		if displayTitle == "" {
			displayTitle = searchedTitle
		}
	}

	if displayTitle == "" {
		displayTitle = ReleaseDisplayTitle(title, mediaType)
	}

	if posterURL == "" && overview == "" && tmdbID == 0 {
		if displayTitle == "" || displayTitle == title {
			return false
		}
	}

	_, err := database.DB.Exec(`
		UPDATE medias SET
			title = CASE WHEN ? != '' THEN ? ELSE title END,
			poster_url = CASE WHEN ? != '' THEN ? ELSE poster_url END,
			overview = CASE WHEN ? != '' THEN ? ELSE overview END,
			release_date = CASE WHEN ? != '' AND (release_date IS NULL OR release_date = '') THEN ? ELSE release_date END,
			tmdb_id = CASE WHEN ? > 0 AND (tmdb_id IS NULL OR tmdb_id = 0) THEN ? ELSE tmdb_id END
		WHERE id = ?`,
		displayTitle, displayTitle,
		posterURL, posterURL,
		overview, overview,
		releaseDate, releaseDate,
		tmdbID, tmdbID,
		id,
	)
	if err != nil {
		log.Printf("TMDB: failed to update media %d: %v", id, err)
		return false
	}

	if posterURL != "" || overview != "" {
		log.Printf("TMDB: enriched %s %q (id=%d)", mediaType, displayTitle, id)
	}
	return posterURL != "" || overview != ""
}

func getShowPosterForSeason(seasonID int) string {
	var poster sql.NullString
	_ = database.DB.QueryRow(`
		SELECT s.poster_url FROM medias season
		JOIN medias s ON season.parent_id = s.id AND s.type = 'show'
		WHERE season.id = ?`, seasonID).Scan(&poster)
	if poster.Valid {
		return poster.String
	}
	return ""
}

func backfillEpisodePosters() {
	res, err := database.DB.Exec(`
		UPDATE medias AS ep
		SET poster_url = (
			SELECT show_m.poster_url FROM medias season
			JOIN medias show_m ON season.parent_id = show_m.id AND show_m.type = 'show'
			WHERE season.id = ep.parent_id
			  AND show_m.poster_url IS NOT NULL AND show_m.poster_url != ''
			LIMIT 1
		)
		WHERE ep.type = 'episode'
		  AND (ep.poster_url IS NULL OR ep.poster_url = '')
	`)
	if err != nil {
		log.Printf("TMDB: episode poster backfill failed: %v", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		log.Printf("TMDB: copied show posters to %d episodes", n)
	}
}

func loadBackfillQueue() []struct {
	id        int
	mediaType models.MediaType
	title     string
	filePath  string
	tmdbID    int
} {
	rows, err := database.DB.Query(`
		SELECT id, type, title, COALESCE(file_path, ''), COALESCE(tmdb_id, 0)
		FROM medias
		WHERE type IN ('movie', 'show')
		  AND (
		    poster_url IS NULL OR poster_url = ''
		    OR overview IS NULL OR overview = ''
		    OR tmdb_id IS NULL OR tmdb_id = 0
		    OR title LIKE '%WEBDL%'
		    OR title LIKE '%webdl%'
		    OR title LIKE '%.mkv%'
		    OR title LIKE '%1080p%'
		    OR title LIKE '%720p%'
		  )
		ORDER BY type, title
	`)
	if err != nil {
		log.Printf("TMDB: backfill query failed: %v", err)
		return nil
	}
	defer rows.Close()

	var items []struct {
		id        int
		mediaType models.MediaType
		title     string
		filePath  string
		tmdbID    int
	}
	for rows.Next() {
		var id, tmdbID int
		var mediaType, title, filePath string
		if err := rows.Scan(&id, &mediaType, &title, &filePath, &tmdbID); err != nil {
			continue
		}
		items = append(items, struct {
			id        int
			mediaType models.MediaType
			title     string
			filePath  string
			tmdbID    int
		}{id, models.MediaType(mediaType), title, filePath, tmdbID})
	}
	return items
}

// backfillMissingMetadata fetches TMDB posters for movies/shows missing
// artwork. The run guard belongs to BackfillMissingMetadataAsync, its only
// caller, so that a trigger can answer 409 without racing.
func backfillMissingMetadata() {

	if tmdbAPIKey() == "" {
		log.Println("TMDB: backfill skipped — set TMDB_API_KEY in your environment")
		backfillEpisodePosters()
		return
	}

	log.Println("TMDB: starting metadata backfill…")
	start := time.Now()

	// Load the full queue first — never hold a rows cursor open during HTTP/UPDATE
	// (SQLite uses a single connection; open rows + Exec deadlocks forever).
	queue := loadBackfillQueue()
	log.Printf("TMDB: %d items need metadata", len(queue))

	updated := 0
	for i, item := range queue {
		searchTitle := enrichSearchTitle(item.title, item.filePath, item.mediaType, item.id)
		if enrichMediaRecord(item.id, searchTitle, item.mediaType, item.tmdbID) {
			updated++
		}
		if (i+1)%25 == 0 || i+1 == len(queue) {
			log.Printf("TMDB: backfill progress %d/%d", i+1, len(queue))
		}
		time.Sleep(260 * time.Millisecond)
	}

	backfillEpisodePosters()
	backfillLocalizedTitles()
	backfillEpisodeMetadata()
	log.Printf("TMDB: metadata backfill done in %v (%d updated)", time.Since(start), updated)
}

func backfillLocalizedTitles() {
	if tmdbAPIKey() == "" {
		return
	}

	rows, err := database.DB.Query(`
		SELECT id, type, COALESCE(tmdb_id, 0)
		FROM medias
		WHERE type IN ('movie', 'show')
		  AND tmdb_id IS NOT NULL AND tmdb_id > 0
		ORDER BY type, title`)
	if err != nil {
		log.Printf("TMDB: localized title backfill query failed: %v", err)
		return
	}
	defer rows.Close()

	type item struct {
		id        int
		mediaType models.MediaType
		tmdbID    int
	}
	var queue []item
	for rows.Next() {
		var id, tmdbID int
		var mediaType string
		if err := rows.Scan(&id, &mediaType, &tmdbID); err != nil {
			continue
		}
		queue = append(queue, item{id, models.MediaType(mediaType), tmdbID})
	}

	if len(queue) == 0 {
		return
	}

	log.Printf("TMDB: refreshing localized titles for %d items (%s)…", len(queue), tmdbLanguage())
	updated := 0
	for i, item := range queue {
		if refreshLocalizedRecord(item.id, item.tmdbID, item.mediaType) {
			updated++
		}
		if (i+1)%25 == 0 || i+1 == len(queue) {
			log.Printf("TMDB: localized titles progress %d/%d", i+1, len(queue))
		}
		time.Sleep(260 * time.Millisecond)
	}
	log.Printf("TMDB: localized titles refreshed (%d updated)", updated)
}

func refreshLocalizedRecord(id, tmdbID int, mediaType models.MediaType) bool {
	_, overview, _, displayTitle := fetchTMDBDetailsByID(tmdbID, mediaType)
	if displayTitle == "" && overview == "" {
		return false
	}

	_, err := database.DB.Exec(`
		UPDATE medias SET
			title = CASE WHEN ? != '' THEN ? ELSE title END,
			overview = CASE WHEN ? != '' THEN ? ELSE overview END
		WHERE id = ?`,
		displayTitle, displayTitle,
		overview, overview,
		id,
	)
	if err != nil {
		log.Printf("TMDB: failed to localize media %d: %v", id, err)
		return false
	}
	return displayTitle != ""
}

// SearchTMDBCandidates returns up to 20 TMDB matches for a manual query, used
// by the "fix metadata" poster picker.
func SearchTMDBCandidates(query string, mediaType models.MediaType) []models.TMDBSearchCandidate {
	apiKey := tmdbAPIKey()
	query = strings.TrimSpace(query)
	if apiKey == "" || query == "" {
		return nil
	}

	endpoint := "movie"
	typeLabel := string(models.TypeMovie)
	if mediaType == models.TypeShow {
		endpoint = "tv"
		typeLabel = string(models.TypeShow)
	}

	u := fmt.Sprintf(
		"https://api.themoviedb.org/3/search/%s?api_key=%s&query=%s&language=%s",
		endpoint, apiKey, url.QueryEscape(query), tmdbLanguage(),
	)
	resp, err := httpx.Standard.Get(u)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return nil
	}
	defer resp.Body.Close()

	var out TMDBResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}

	var candidates []models.TMDBSearchCandidate
	for _, r := range out.Results {
		date := r.ReleaseDate
		if mediaType == models.TypeShow {
			date = r.FirstAirDate
		}
		candidates = append(candidates, models.TMDBSearchCandidate{
			TMDBID:    r.ID,
			Title:     tmdbDisplayTitle(r.Title, r.Name, mediaType),
			Year:      yearFromDate(date),
			Overview:  strings.TrimSpace(r.Overview),
			PosterURL: posterURLFromPath(r.PosterPath),
			MediaType: typeLabel,
		})
		if len(candidates) >= 20 {
			break
		}
	}
	return candidates
}

// RematchMediaByID re-identifies a movie/show against TMDB, overriding any
// previously stored (possibly wrong) match. When overrideTMDBID > 0 the exact
// TMDB entry is used; otherwise a fresh search runs on overrideTitle (or the
// original release filename when empty). Returns true on a successful update.
func RematchMediaByID(id int, overrideTitle string, overrideTMDBID int) bool {
	var title, mediaType, filePath string
	err := database.DB.QueryRow(
		`SELECT title, type, COALESCE(file_path, '') FROM medias WHERE id = ? AND type IN ('movie', 'show')`, id,
	).Scan(&title, &mediaType, &filePath)
	if err != nil {
		return false
	}
	mt := models.MediaType(mediaType)

	var posterURL, overview, releaseDate, displayTitle, imdbID string
	var tmdbID int

	if overrideTMDBID > 0 {
		posterURL, overview, releaseDate, displayTitle = fetchTMDBDetailsByID(overrideTMDBID, mt)
		tmdbID = overrideTMDBID
	} else if strings.TrimSpace(overrideTitle) != "" {
		identity := IdentifyFromRawName(overrideTitle, mt)
		posterURL, overview, releaseDate = identity.PosterURL, identity.Overview, identity.ReleaseDate
		displayTitle = identity.Title
		imdbID = identity.IMDbID
		if identity.Matched {
			tmdbID = identity.TMDBID
		}
	} else {
		identity := redetectIdentity(id, mt, filePath, title)
		posterURL, overview, releaseDate = identity.PosterURL, identity.Overview, identity.ReleaseDate
		displayTitle = identity.Title
		imdbID = identity.IMDbID
		if identity.Matched {
			tmdbID = identity.TMDBID
		}
	}

	if tmdbID == 0 && displayTitle == "" {
		return false
	}
	// Auto redetect/rematch must not wipe a previous good match with an unmatched result.
	if overrideTMDBID == 0 && strings.TrimSpace(overrideTitle) == "" && tmdbID == 0 {
		log.Printf("TMDB: rematch skipped for media %d — no confident identity", id)
		return false
	}
	if displayTitle == "" {
		if overrideTitle != "" {
			displayTitle = strings.TrimSpace(overrideTitle)
		} else {
			displayTitle = ReleaseDisplayTitle(enrichSearchTitle(title, filePath, mt, id), mt)
		}
	}

	// Overwrite the stored metadata unconditionally — this is an explicit fix.
	_, err = database.DB.Exec(`
		UPDATE medias SET
			title = CASE WHEN ? != '' THEN ? ELSE title END,
			poster_url = ?,
			overview = ?,
			release_date = ?,
			tmdb_id = ?,
			imdb_id = COALESCE(NULLIF(?, ''), imdb_id)
		WHERE id = ?`,
		displayTitle, displayTitle,
		posterURL,
		overview,
		releaseDate,
		tmdbID,
		imdbID,
		id,
	)
	if err != nil {
		log.Printf("TMDB: failed to rematch media %d: %v", id, err)
		return false
	}
	log.Printf("TMDB: rematched %s %q (id=%d, tmdb=%d)", mediaType, displayTitle, id, tmdbID)
	return true
}

func redetectIdentity(id int, mt models.MediaType, filePath, storedTitle string) IdentityMatch {
	filePath = strings.TrimSpace(filePath)
	switch mt {
	case models.TypeMovie:
		if filePath != "" {
			// Parent of the file is used as library root fallback; folder-first still applies
			// when the movie sits in its own Emby-style directory.
			return IdentifyMovie(filePath, filepath.Dir(filepath.Dir(filePath)))
		}
	case models.TypeShow:
		folder, _ := ShowLocalLibraryHint(id)
		if folder != "" {
			showFolder := ""
			if sample := sampleShowEpisodePath(id); sample != "" {
				cur := filepath.Dir(sample)
				for i := 0; i < 5; i++ {
					base := filepath.Base(cur)
					lower := strings.ToLower(base)
					if !strings.HasPrefix(lower, "season ") && !strings.HasPrefix(lower, "saison ") && !looksLikeEpisodeReleaseFolder(base) {
						showFolder = cur
						break
					}
					parent := filepath.Dir(cur)
					if parent == cur {
						break
					}
					cur = parent
				}
			}
			return IdentifyShow(showFolder, folder)
		}
	}
	return IdentifyFromRawName(enrichSearchTitle(storedTitle, filePath, mt, id), mt)
}

// RedetectMediaByID re-runs TMDB identification from local file/folder names and
// overwrites the stored match (same as rematch without manual pick). For shows,
// episode metadata is refreshed from the new TMDB id.
func RedetectMediaByID(id int) bool {
	if !RematchMediaByID(id, "", 0) {
		return false
	}
	var mediaType string
	if err := database.DB.QueryRow(`SELECT type FROM medias WHERE id = ?`, id).Scan(&mediaType); err != nil {
		return true
	}
	if mediaType == string(models.TypeShow) {
		RefreshAllSeasonsEpisodesFromTMDB(id)
	}
	return true
}

// EnrichMediaByID fetches TMDB metadata for a single movie/show.
func EnrichMediaByID(id int) bool {
	var title, mediaType, filePath string
	var tmdbID int
	err := database.DB.QueryRow(`
		SELECT title, type, COALESCE(file_path, ''), COALESCE(tmdb_id, 0)
		FROM medias WHERE id = ? AND type IN ('movie', 'show')`, id,
	).Scan(&title, &mediaType, &filePath, &tmdbID)
	if err != nil {
		return false
	}
	return enrichMediaRecord(id, enrichSearchTitle(title, filePath, models.MediaType(mediaType), id), models.MediaType(mediaType), tmdbID)
}

// BackfillMissingMetadataAsync runs backfill in the background. It claims the
// run before returning, so the caller learns whether it started one — checking
// IsBackfilling() first would race with another request doing the same.
func BackfillMissingMetadataAsync() bool {
	if !backfilling.CompareAndSwap(false, true) {
		return false
	}
	go func() {
		defer backfilling.Store(false)
		backfillMissingMetadata()
	}()
	return true
}

// RedetectAllProgress tracks bulk re-identification for GET /api/indexer/status.
type RedetectAllProgress struct {
	Total     int `json:"total"`
	Processed int `json:"processed"`
	Updated   int `json:"updated"`
	Skipped   int `json:"skipped"`
}

// redetectingAll is the run guard; redetectAllMutex still protects the progress
// counters, which are a struct and cannot be made atomic on their own.
var (
	redetectingAll      atomic.Bool
	redetectAllMutex    sync.Mutex
	redetectAllProgress RedetectAllProgress
)

// IsRedetectingAll reports whether a bulk metadata redetect is running.
func IsRedetectingAll() bool { return redetectingAll.Load() }

// RedetectAllProgressSnapshot returns a copy of the current bulk redetect counters.
func RedetectAllProgressSnapshot() RedetectAllProgress {
	redetectAllMutex.Lock()
	defer redetectAllMutex.Unlock()
	return redetectAllProgress
}

// RedetectAllMediaAsync re-runs Emby-style identification on every movie and
// show. It claims the run before returning, so the caller learns whether it
// started one rather than checking IsRedetectingAll() and racing.
func RedetectAllMediaAsync() bool {
	if !redetectingAll.CompareAndSwap(false, true) {
		log.Println("Identify: bulk redetect already in progress")
		return false
	}
	go func() {
		defer redetectingAll.Store(false)
		redetectAllMedia()
	}()
	return true
}

// redetectAllMedia walks all library movies/shows and applies RedetectMediaByID.
// The run guard belongs to RedetectAllMediaAsync, its only caller.
func redetectAllMedia() {
	redetectAllMutex.Lock()
	redetectAllProgress = RedetectAllProgress{}
	redetectAllMutex.Unlock()

	start := time.Now()
	rows, err := database.DB.Query(`
		SELECT id FROM medias WHERE type IN ('movie', 'show') ORDER BY type, id`)
	if err != nil {
		log.Printf("Identify: bulk redetect query failed: %v", err)
		return
	}
	defer rows.Close()

	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			continue
		}
		ids = append(ids, id)
	}

	redetectAllMutex.Lock()
	redetectAllProgress.Total = len(ids)
	redetectAllMutex.Unlock()

	log.Printf("Identify: bulk redetect starting for %d movie(s)/show(s)", len(ids))

	for _, id := range ids {
		ok := RedetectMediaByID(id)
		redetectAllMutex.Lock()
		redetectAllProgress.Processed++
		if ok {
			redetectAllProgress.Updated++
		} else {
			redetectAllProgress.Skipped++
		}
		redetectAllMutex.Unlock()
	}

	dedupeDuplicateShows()
	dedupeDuplicateMovies()
	InvalidateStreamCaches()

	redetectAllMutex.Lock()
	snap := redetectAllProgress
	redetectAllMutex.Unlock()
	log.Printf(
		"Identify: bulk redetect done in %v — updated %d, skipped %d, total %d",
		time.Since(start), snap.Updated, snap.Skipped, snap.Total,
	)
}
