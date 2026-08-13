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

// ResolveMovieLookupName prefers the parent folder name (Emby movie layout) over
// a bare/generic filename when the file is not directly under the library root.
func ResolveMovieLookupName(videoPath, moviesRoot string) string {
	videoPath = filepath.Clean(videoPath)
	moviesRoot = filepath.Clean(moviesRoot)
	fileBase := strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath))
	parentDir := filepath.Dir(videoPath)
	parentName := filepath.Base(parentDir)

	if moviesRoot != "" && samePath(parentDir, moviesRoot) {
		return fileBase
	}
	if looksLikeLibraryRootName(parentName) {
		return fileBase
	}
	if parentName == "" || parentName == "." || parentName == string(filepath.Separator) {
		return fileBase
	}

	// Emby: folder is the identity source when the movie lives in its own folder.
	if looksLikeGenericVideoName(fileBase) || folderLooksLikeMovieContainer(parentName) {
		return parentName
	}
	// Prefer folder when it carries year / provider IDs (strong Emby signal).
	if extractYear(parentName) > 0 || providerTMDBRe.MatchString(parentName) || providerIMDbRe.MatchString(parentName) {
		return parentName
	}
	return parentName
}

func looksLikeGenericVideoName(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	switch lower {
	case "", "movie", "video", "film", "feature", "movie title", "sample":
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

func folderLooksLikeMovieContainer(name string) bool {
	cleaned := StripProviderIDs(name)
	return strings.TrimSpace(cleaned) != ""
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
	Title     string     `xml:"title"`
	Year      string     `xml:"year"`
	TMDBID    string     `xml:"tmdbid"`
	IMDbID    string     `xml:"imdbid"`
	TVDBID    string     `xml:"tvdbid"`
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

	// 1) Provider IDs in folder + filename (highest local certainty after NFO).
	for _, part := range []string{filepath.Base(filepath.Dir(videoPath)), filepath.Base(videoPath), lookupName} {
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
	if nfo := ReadNFOIdentity(MovieNFOCandidates(videoPath)...); nfo.Source == "nfo" {
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
