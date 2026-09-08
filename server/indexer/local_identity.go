package indexer

import (
	"encoding/xml"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"project-player/server/models"
)

// LocalIdentityHints holds Emby/Jellyfin-style identity signals found on disk
// before any remote TMDB search (provider IDs in names, NFO sidecars, folder hints).
type LocalIdentityHints struct {
	TMDBID int
	IMDbID string
	TVDBID int
	Title  string
	Year   int
	Source string // path_id | nfo | folder | filename
}

var (
	providerTMDBRe = regexp.MustCompile(`(?i)[\[{](?:tmdb(?:id)?|themoviedb)[-_]?(\d+)[\]}]`)
	providerIMDbRe = regexp.MustCompile(`(?i)[\[{](?:imdb(?:id)?)[-_]?(tt\d+)[\]}]`)
	providerTVDBRe = regexp.MustCompile(`(?i)[\[{](?:tvdb(?:id)?|thetvdb)[-_]?(\d+)[\]}]`)

	// Expanded episode patterns (Emby/Jellyfin naming engine style).
	episodePatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\b[Ss](\d{1,2})[Ee](\d{1,3})\b`),
		regexp.MustCompile(`(?i)\b[Ss](\d{1,2})\.?[Ee](\d{1,3})\b`),
		regexp.MustCompile(`(?i)\b(\d{1,2})[xX](\d{1,3})\b`),
		regexp.MustCompile(`(?i)(?:Season|Saison)\s*(\d{1,2}).*?(?:Episode|Ep(?:isode)?)\s*(\d{1,3})`),
	}
)

// ExtractProviderIDs parses Emby/Jellyfin provider tags from a folder or file name.
func ExtractProviderIDs(name string) (tmdbID int, imdbID string, tvdbID int) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, "", 0
	}
	if m := providerTMDBRe.FindStringSubmatch(name); len(m) == 2 {
		tmdbID, _ = strconv.Atoi(m[1])
	}
	if m := providerIMDbRe.FindStringSubmatch(name); len(m) == 2 {
		imdbID = strings.ToLower(m[1])
	}
	if m := providerTVDBRe.FindStringSubmatch(name); len(m) == 2 {
		tvdbID, _ = strconv.Atoi(m[1])
	}
	return tmdbID, imdbID, tvdbID
}

// StripProviderIDs removes [tmdbid-…] / [imdbid-…] tags so titles stay clean.
func StripProviderIDs(name string) string {
	name = providerTMDBRe.ReplaceAllString(name, " ")
	name = providerIMDbRe.ReplaceAllString(name, " ")
	name = providerTVDBRe.ReplaceAllString(name, " ")
	return strings.TrimSpace(spaceRe.ReplaceAllString(name, " "))
}

// ParseEpisodeNumbers extracts season/episode from common Emby-compatible patterns.
func ParseEpisodeNumbers(filename string) (seasonNum, episodeNum int, ok bool) {
	base := strings.TrimSuffix(filepath.Base(filename), filepath.Ext(filename))
	for _, re := range episodePatterns {
		matches := re.FindStringSubmatch(base)
		if len(matches) < 3 {
			continue
		}
		sNum, err1 := strconv.Atoi(matches[1])
		eNum, err2 := strconv.Atoi(matches[2])
		if err1 != nil || err2 != nil || sNum < 0 || eNum <= 0 {
			continue
		}
		return sNum, eNum, true
	}
	return 0, 0, false
}

var (
	seasonFolderRe  = regexp.MustCompile(`(?i)^(?:season|saison|series|s)[\s._-]*(\d{1,2})$`)
	bareNumberRe    = regexp.MustCompile(`^(\d{1,3})$`)
	leadingEpRe     = regexp.MustCompile(`^(\d{1,3})\s*[-–_.]\s*\S`)
	markedEpisodeRe = regexp.MustCompile(`(?i)(?:\bep(?:isode)?|épisode|\be)[\s._-]*(\d{1,3})\b`)
	// "Kaamelott - 01 - Heat": the number framed by dashes is the episode.
	dashedEpisodeRe = regexp.MustCompile(`[\s._][-–][\s._]*(\d{1,3})[\s._]*[-–][\s._]`)
)

// seasonNumberFromFolders reads "Season 2" / "Saison 2" / "S02" / "2" from the
// folders above the file, deepest first.
func seasonNumberFromFolders(relParts []string) (int, bool) {
	for i := len(relParts) - 2; i >= 0; i-- {
		part := strings.TrimSpace(relParts[i])
		if part == "" {
			continue
		}
		if m := seasonFolderRe.FindStringSubmatch(part); len(m) == 2 {
			if n, err := strconv.Atoi(m[1]); err == nil && n >= 0 {
				return n, true
			}
		}
		if m := bareNumberRe.FindStringSubmatch(part); len(m) == 2 {
			if n, err := strconv.Atoi(m[1]); err == nil && n > 0 && n <= 50 {
				return n, true
			}
		}
	}
	return 0, false
}

// episodeNumberFromFileName reads an episode number from names without SxxExx
// ("01 - Titre.mkv", "Episode 4.mkv", "12.mkv").
func episodeNumberFromFileName(fileName string, hasSeasonFolder bool) (int, bool) {
	base := strings.TrimSuffix(filepath.Base(fileName), filepath.Ext(fileName))
	base = strings.TrimSpace(StripProviderIDs(base))

	if m := bareNumberRe.FindStringSubmatch(base); len(m) == 2 {
		if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
			return n, true
		}
	}
	if m := markedEpisodeRe.FindStringSubmatch(base); len(m) == 2 {
		if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
			return n, true
		}
	}
	if m := dashedEpisodeRe.FindStringSubmatch(base); len(m) == 2 {
		if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
			return n, true
		}
	}
	// A bare leading number is only trustworthy inside a season folder.
	if hasSeasonFolder {
		if m := leadingEpRe.FindStringSubmatch(base); len(m) == 2 {
			if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
				return n, true
			}
		}
	}
	return 0, false
}

// ResolveEpisodeNumbers finds season/episode numbers from the filename, then
// from the folder layout — Emby indexes "Saison 1/01 - Titre.mkv" too, and
// dropping those files silently loses whole seasons.
func ResolveEpisodeNumbers(relParts []string, fileName string) (seasonNum, episodeNum int, ok bool) {
	if s, e, found := ParseEpisodeNumbers(fileName); found {
		return s, e, true
	}
	season, hasSeason := seasonNumberFromFolders(relParts)
	episode, found := episodeNumberFromFileName(fileName, hasSeason)
	if !found {
		return 0, 0, false
	}
	if !hasSeason {
		season = 1
	}
	return season, episode, true
}

// ResolveMovieLookupName returns the name a movie should be identified from.
//
// Emby rule: the folder names the movie only when the movie owns that folder
// ("Inception (2010)/movie.mkv"). A folder holding several different movies is a
// category/saga folder ("Films/Action/…", "Saga Harry Potter/…") and must never
// name them — doing so gives every file in it the same identity, which then
// collapses the whole folder onto a single TMDB match.
func ResolveMovieLookupName(videoPath, moviesRoot string) string {
	videoPath = filepath.Clean(videoPath)
	moviesRoot = filepath.Clean(moviesRoot)
	fileBase := strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath))
	parentDir := filepath.Dir(videoPath)
	parentName := filepath.Base(parentDir)

	if moviesRoot != "" && samePath(parentDir, moviesRoot) {
		return fileBase
	}
	if parentName == "" || parentName == "." || parentName == string(filepath.Separator) {
		return fileBase
	}
	if looksLikeLibraryRootName(parentName) || looksLikeCategoryFolderName(parentName) {
		return fileBase
	}
	if strings.TrimSpace(StripProviderIDs(parentName)) == "" {
		return fileBase
	}

	// A folder with several distinct movies names none of them.
	if CountDistinctMoviesInDir(parentDir) > 1 {
		return fileBase
	}
	// The filename carries nothing usable — the folder is all we have.
	if looksLikeGenericVideoName(fileBase) {
		return parentName
	}
	// Single-movie folder: Emby trusts the folder, it is usually the cleaner name.
	return parentName
}

func looksLikeGenericVideoName(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	switch lower {
	case "", "movie", "video", "film", "feature", "movie title", "sample":
		return true
	}
	// "VIDEO_TS", "title00", "BDMV", "00001" and friends carry no title.
	if strings.HasPrefix(lower, "video_ts") || strings.HasPrefix(lower, "vts_") || lower == "index" {
		return true
	}
	if _, err := strconv.Atoi(strings.TrimSpace(lower)); err == nil {
		return true
	}
	return false
}

func looksLikeLibraryRootName(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "movies", "movie", "films", "film", "media", "library", "videos", "vidéos", "series", "shows", "tv", "tv shows":
		return true
	}
	return false
}

// looksLikeCategoryFolderName recognises grouping folders (genre, alphabet,
// quality, saga…) that must not be used as a movie or show title.
func looksLikeCategoryFolderName(name string) bool {
	lower := stripDiacritics(strings.ToLower(strings.TrimSpace(StripProviderIDs(name))))
	if lower == "" {
		return true
	}
	if looksLikeLibraryRootName(lower) {
		return true
	}
	switch lower {
	case "series", "serie", "saisons", "seasons", "emissions", "spectacle tv":
		return true
	}
	// Alphabet buckets: "A", "0-9", "#".
	if len([]rune(lower)) <= 2 {
		return true
	}
	// Purely numeric folders group by year/decade ("2024", "1990s"), they never
	// name a film — the filename inside does.
	if _, err := strconv.Atoi(strings.TrimSuffix(lower, "s")); err == nil {
		return true
	}
	switch lower {
	case "action", "aventure", "adventure", "animation", "animations", "anime", "animes",
		"comedie", "comédie", "comedy", "documentaire", "documentaires", "documentary",
		"drame", "drama", "fantastique", "fantasy", "horreur", "horror", "thriller",
		"policier", "romance", "science fiction", "science-fiction", "sci-fi", "sf",
		"guerre", "war", "western", "musical", "biopic", "famille", "family",
		"enfants", "kids", "jeunesse", "concert", "concerts", "spectacle", "spectacles",
		"divers", "autres", "others", "misc", "nouveautes", "nouveautés", "new", "recents", "récents",
		"vf", "vostfr", "multi", "4k", "uhd", "hd", "1080p", "720p", "2160p",
		"a voir", "à voir", "vus", "non vus", "collection", "collections", "saga", "sagas",
		"trilogie", "trilogy", "quadrilogie", "pentalogie", "integrale", "intégrale", "coffret":
		return true
	}
	// "Saga Harry Potter", "Collection Marvel", "Trilogie Le Seigneur des Anneaux"…
	for _, prefix := range []string{"saga ", "collection ", "coffret ", "trilogie ", "quadrilogie ", "integrale ", "intégrale ", "pack "} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func samePath(a, b string) bool {
	a = filepath.Clean(a)
	b = filepath.Clean(b)
	if a == b {
		return true
	}
	// Best-effort case-insensitive compare (useful on macOS).
	return strings.EqualFold(a, b)
}

type nfoRoot struct {
	XMLName   xml.Name
	Title     string      `xml:"title"`
	Year      string      `xml:"year"`
	TMDBID    string      `xml:"tmdbid"`
	IMDbID    string      `xml:"imdbid"`
	TVDBID    string      `xml:"tvdbid"`
	UniqueIDs []nfoUnique `xml:"uniqueid"`
}

type nfoUnique struct {
	Type    string `xml:"type,attr"`
	Default string `xml:"default,attr"`
	Value   string `xml:",chardata"`
}

// ReadNFOIdentity reads Emby/Kodi-compatible NFO beside a video or in a show folder.
func ReadNFOIdentity(paths ...string) LocalIdentityHints {
	for _, p := range paths {
		if hints, ok := parseNFOFile(p); ok {
			return hints
		}
	}
	return LocalIdentityHints{}
}

func parseNFOFile(path string) (LocalIdentityHints, bool) {
	path = strings.TrimSpace(path)
	if path == "" {
		return LocalIdentityHints{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return LocalIdentityHints{}, false
	}

	var root nfoRoot
	if err := xml.Unmarshal(data, &root); err != nil {
		// Soft fallback: regex extract when XML is messy / has BOM noise.
		return parseNFOLoose(string(data))
	}

	hints := LocalIdentityHints{Source: "nfo", Title: strings.TrimSpace(root.Title)}
	if y, err := strconv.Atoi(strings.TrimSpace(root.Year)); err == nil {
		hints.Year = y
	}
	if id, err := strconv.Atoi(strings.TrimSpace(root.TMDBID)); err == nil {
		hints.TMDBID = id
	}
	hints.IMDbID = normalizeIMDbID(root.IMDbID)
	if id, err := strconv.Atoi(strings.TrimSpace(root.TVDBID)); err == nil {
		hints.TVDBID = id
	}
	for _, u := range root.UniqueIDs {
		typ := strings.ToLower(strings.TrimSpace(u.Type))
		val := strings.TrimSpace(u.Value)
		switch typ {
		case "tmdb", "themoviedb":
			if hints.TMDBID == 0 {
				if id, err := strconv.Atoi(val); err == nil {
					hints.TMDBID = id
				}
			}
		case "imdb":
			if hints.IMDbID == "" {
				hints.IMDbID = normalizeIMDbID(val)
			}
		case "tvdb", "thetvdb":
			if hints.TVDBID == 0 {
				if id, err := strconv.Atoi(val); err == nil {
					hints.TVDBID = id
				}
			}
		}
	}
	if hints.TMDBID == 0 && hints.IMDbID == "" && hints.TVDBID == 0 && hints.Title == "" {
		return LocalIdentityHints{}, false
	}
	return hints, true
}

func parseNFOLoose(raw string) (LocalIdentityHints, bool) {
	hints := LocalIdentityHints{Source: "nfo"}
	if m := regexp.MustCompile(`(?i)<tmdbid>\s*(\d+)\s*</tmdbid>`).FindStringSubmatch(raw); len(m) == 2 {
		hints.TMDBID, _ = strconv.Atoi(m[1])
	}
	if m := regexp.MustCompile(`(?i)<uniqueid[^>]*type=["']tmdb["'][^>]*>\s*(\d+)\s*</uniqueid>`).FindStringSubmatch(raw); len(m) == 2 && hints.TMDBID == 0 {
		hints.TMDBID, _ = strconv.Atoi(m[1])
	}
	if m := regexp.MustCompile(`(?i)<imdbid>\s*(tt\d+)\s*</imdbid>`).FindStringSubmatch(raw); len(m) == 2 {
		hints.IMDbID = normalizeIMDbID(m[1])
	}
	if m := regexp.MustCompile(`(?i)<uniqueid[^>]*type=["']imdb["'][^>]*>\s*(tt\d+)\s*</uniqueid>`).FindStringSubmatch(raw); len(m) == 2 && hints.IMDbID == "" {
		hints.IMDbID = normalizeIMDbID(m[1])
	}
	if m := regexp.MustCompile(`(?i)<title>\s*([^<]+)\s*</title>`).FindStringSubmatch(raw); len(m) == 2 {
		hints.Title = strings.TrimSpace(m[1])
	}
	if m := regexp.MustCompile(`(?i)<year>\s*(\d{4})\s*</year>`).FindStringSubmatch(raw); len(m) == 2 {
		hints.Year, _ = strconv.Atoi(m[1])
	}
	if hints.TMDBID == 0 && hints.IMDbID == "" && hints.Title == "" {
		return LocalIdentityHints{}, false
	}
	return hints, true
}

func normalizeIMDbID(id string) string {
	id = strings.ToLower(strings.TrimSpace(id))
	if id == "" {
		return ""
	}
	if strings.HasPrefix(id, "tt") {
		return id
	}
	if _, err := strconv.Atoi(id); err == nil {
		return "tt" + id
	}
	return id
}

// MovieNFOCandidates returns likely NFO paths Emby/Kodi would look for.
func MovieNFOCandidates(videoPath string) []string {
	dir := filepath.Dir(videoPath)
	base := strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath))
	return []string{
		filepath.Join(dir, base+".nfo"),
		filepath.Join(dir, "movie.nfo"),
		filepath.Join(dir, "Movie.nfo"),
	}
}

// ShowNFOCandidates returns show-level NFO paths for a series folder.
func ShowNFOCandidates(showFolderPath string) []string {
	if strings.TrimSpace(showFolderPath) == "" {
		return nil
	}
	return []string{
		filepath.Join(showFolderPath, "tvshow.nfo"),
		filepath.Join(showFolderPath, "TVShow.nfo"),
		filepath.Join(showFolderPath, filepath.Base(showFolderPath)+".nfo"),
	}
}

// CollectMovieLocalIdentity gathers Emby-style local signals for a movie file.
func CollectMovieLocalIdentity(videoPath, moviesRoot string) LocalIdentityHints {
	lookupName := ResolveMovieLookupName(videoPath, moviesRoot)
	hints := LocalIdentityHints{Source: "folder", Title: lookupName}

	// Shared folders must not donate an ID or movie.nfo to every file.
	parent := filepath.Dir(videoPath)
	ownsFolder := !samePath(parent, moviesRoot) &&
		!looksLikeCategoryFolderName(filepath.Base(parent)) && CountDistinctMoviesInDir(parent) <= 1
	parts := []string{filepath.Base(videoPath)}
	if ownsFolder {
		parts = append(parts, filepath.Base(filepath.Dir(videoPath)))
	}
	for _, part := range parts {
		tmdbID, imdbID, tvdbID := ExtractProviderIDs(part)
		if hints.TMDBID == 0 && tmdbID > 0 {
			hints.TMDBID = tmdbID
			hints.Source = "path_id"
		}
		if hints.IMDbID == "" && imdbID != "" {
			hints.IMDbID = imdbID
			if hints.Source != "path_id" {
				hints.Source = "path_id"
			}
		}
		if hints.TVDBID == 0 && tvdbID > 0 {
			hints.TVDBID = tvdbID
		}
	}

	// 2) NFO sidecar overrides / fills IDs.
	nfoPaths := MovieNFOCandidates(videoPath)
	if !ownsFolder {
		nfoPaths = nfoPaths[:1]
	}
	if nfo := ReadNFOIdentity(nfoPaths...); nfo.Source == "nfo" {
		if nfo.TMDBID > 0 {
			hints.TMDBID = nfo.TMDBID
		}
		if nfo.IMDbID != "" {
			hints.IMDbID = nfo.IMDbID
		}
		if nfo.TVDBID > 0 {
			hints.TVDBID = nfo.TVDBID
		}
		if nfo.Title != "" {
			hints.Title = nfo.Title
		}
		if nfo.Year > 0 {
			hints.Year = nfo.Year
		}
		hints.Source = "nfo"
	}

	cleaned := StripProviderIDs(hints.Title)
	parsed := ParseReleaseFilename(cleaned, models.TypeMovie)
	if hints.Year == 0 {
		hints.Year = parsed.Year
	}
	if parsed.Title != "" {
		hints.Title = parsed.Title
	} else if cleaned != "" {
		hints.Title = cleaned
	}
	return hints
}

// CollectShowLocalIdentity gathers Emby-style local signals for a show folder/name.
func CollectShowLocalIdentity(showFolderPath, rawSearchKey string) LocalIdentityHints {
	hints := LocalIdentityHints{Source: "folder", Title: rawSearchKey}

	candidates := []string{rawSearchKey, filepath.Base(showFolderPath)}
	for _, part := range candidates {
		tmdbID, imdbID, tvdbID := ExtractProviderIDs(part)
		if hints.TMDBID == 0 && tmdbID > 0 {
			hints.TMDBID = tmdbID
			hints.Source = "path_id"
		}
		if hints.IMDbID == "" && imdbID != "" {
			hints.IMDbID = imdbID
			hints.Source = "path_id"
		}
		if hints.TVDBID == 0 && tvdbID > 0 {
			hints.TVDBID = tvdbID
		}
	}

	if nfo := ReadNFOIdentity(ShowNFOCandidates(showFolderPath)...); nfo.Source == "nfo" {
		if nfo.TMDBID > 0 {
			hints.TMDBID = nfo.TMDBID
		}
		if nfo.IMDbID != "" {
			hints.IMDbID = nfo.IMDbID
		}
		if nfo.TVDBID > 0 {
			hints.TVDBID = nfo.TVDBID
		}
		if nfo.Title != "" {
			hints.Title = nfo.Title
		}
		if nfo.Year > 0 {
			hints.Year = nfo.Year
		}
		hints.Source = "nfo"
	}

	cleaned := StripProviderIDs(hints.Title)
	if cleaned == "" {
		cleaned = StripProviderIDs(rawSearchKey)
	}
	parsed := ParseReleaseFilename(cleaned, models.TypeShow)
	if hints.Year == 0 {
		hints.Year = parsed.Year
	}
	if parsed.Title != "" {
		hints.Title = parsed.Title
	} else if cleaned != "" {
		hints.Title = cleaned
	}
	return hints
}
