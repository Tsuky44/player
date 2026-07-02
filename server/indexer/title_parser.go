package indexer

import (
	"regexp"
	"strconv"
	"strings"
	"time"

	"project-player/server/models"
)

// ParsedReleaseName holds structured info extracted from a release filename.
type ParsedReleaseName struct {
	Title    string
	Year     int
	Original string
}

var (
	yearPattern = regexp.MustCompile(`\b(19[0-9]{2}|20[0-9]{2})\b`)

	tvEpisodeCutPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\b[Ss]\d{1,2}[Ee]\d{1,3}\b`),
		regexp.MustCompile(`(?i)\b[Ss]\d{1,2}\b`),
		regexp.MustCompile(`(?i)\b\d{1,2}[xX]\d{1,3}\b`),
	}

	stripSourceRe = regexp.MustCompile(`(?i)\b(BluRay|BLURAY|BD|BD50|BD25|WEB[-\s]?DL|WEBDL|WEB[-\s]?Rip|WEBRip|WEB|HDTV|PDTV|DVD|DVD[-\s]?Rip|CAM|HD[-\s]?CAM|TS|HD[-\s]?TS|TC)\b`)
	stripQualityRe = regexp.MustCompile(`(?i)\b(4K|UHD|2160p|1080p|1080i|720p|480p|360p|HDR|HDR10|HDR10\+|DV|REMUX|4KLight|1080pLight|720pLight|4K-Light|1080p-Light|720p-Light)\b`)
	stripCodecRe   = regexp.MustCompile(`(?i)\b(10bit|10\-bit|8bit|8\-bit|12bit|12\-bit|HEVC|x265|x264|H\.265|H\.264|AVC|AV1|VP9|MPEG[-\s]?2|MPEG[-\s]?4|XviD|DivX)\b`)
	stripAudioRe   = regexp.MustCompile(`(?i)\b(DD[\s+]?5\.1|DD[\s+]?2\.0|AC3|DTS[-\s]?HD|DTS[-\s]?X|DTS|TrueHD|Atmos|AAC|FLAC|MP3|5\.1|7\.1|2\.0)\b`)
	stripLangRe    = regexp.MustCompile(`(?i)\b(VOSTFR|SUBFRENCH|SUB|FRENCH|FRA|VF|VF2|VFF|VFQ|VFI|ENGLISH|ENG|VO|VOST|MULTI|TRUEFRENCH)\b`)
	stripFeatureRe = regexp.MustCompile(`(?i)\b(Hybrid|Unrated|Extended|Remastered|Director's[\s-]?Cut|Collector|Special[\s-]?Edition)\b`)
	stripGroupRe   = regexp.MustCompile(`(?i)[-\[(]\s*[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*\s*[\])]?$`)
	stripEpisodeRe = regexp.MustCompile(`(?i)[Ss]\d{1,2}[Ee]\d{1,3}(?:[-~][Ee]?\d{1,3})?|[Ss]\d{1,2}\.?[Ee]\d{1,3}|\b[Ss]\d{1,2}\b|\d{1,2}[xX]\d{1,3}(?:[-~]\d{1,3})?|(?:Season|Saison)\s*\d{1,2}|[Ee]p(?:isode)?\s*\d{1,3}`)
	stripExtRe     = regexp.MustCompile(`(?i)\b(mkv|mp4|avi|mov|wmv|m4v|mpg|mpeg|flv)\b`)
	stripGameRe    = regexp.MustCompile(`(?i)\b(REPACK|PROPER|RELOADED|SKIDROW|CODEX|FLT|RUNE|CRACK|CRACKED|STEAMWORKS|GOG|GOTY|Game of the Year|Definitive|Ultimate|Collector|Edition)\b`)
	stripGameTailRe = regexp.MustCompile(`(?i)\b(Update|Patch|DLC|Build|Version)\b.*$`)
	extraCleanRe   = regexp.MustCompile(`(?i)\b(x264|x265|hevc|h264|h265|aac|dts|ac3|multi|vff|vf|vostfr|subfrench|french|eng|english|bluray|webrip|web|hd|uhd|complete|pack|saison\s*\d+|season\s*\d+|integrale|rip|ld|dvd|hdlight|remux|custom|webdl)\b`)
	bracketRe      = regexp.MustCompile(`[\[\]()]+`)
	spaceRe        = regexp.MustCompile(`\s+`)
)

func normalizeSeparators(name string) string {
	name = strings.TrimSuffix(name, ".torrent")
	name = regexp.MustCompile(`[._\-]+`).ReplaceAllString(name, " ")
	return strings.TrimSpace(name)
}

func extractYear(name string) int {
	match := yearPattern.FindStringSubmatch(name)
	if len(match) < 2 {
		return 0
	}
	year, err := strconv.Atoi(match[1])
	if err != nil {
		return 0
	}
	maxYear := time.Now().Year() + 1
	if year >= 1900 && year <= maxYear {
		return year
	}
	return 0
}

func cutBeforeTVPattern(title string) string {
	for _, re := range tvEpisodeCutPatterns {
		loc := re.FindStringIndex(title)
		if loc != nil {
			return strings.TrimSpace(title[:loc[0]])
		}
	}
	return title
}

func cutBeforeYear(title string) string {
	loc := yearPattern.FindStringIndex(title)
	if loc != nil {
		return strings.TrimSpace(title[:loc[0]])
	}
	return title
}

func stripReleaseTags(title string, removeEpisodes bool) string {
	title = stripSourceRe.ReplaceAllString(title, " ")
	title = stripQualityRe.ReplaceAllString(title, " ")
	title = stripCodecRe.ReplaceAllString(title, " ")
	title = stripAudioRe.ReplaceAllString(title, " ")
	title = stripLangRe.ReplaceAllString(title, " ")
	title = stripFeatureRe.ReplaceAllString(title, " ")
	title = stripGroupRe.ReplaceAllString(title, " ")
	title = yearPattern.ReplaceAllString(title, " ")
	if removeEpisodes {
		title = stripEpisodeRe.ReplaceAllString(title, " ")
	}
	title = stripGameRe.ReplaceAllString(title, " ")
	title = stripGameTailRe.ReplaceAllString(title, " ")
	title = stripExtRe.ReplaceAllString(title, " ")
	title = bracketRe.ReplaceAllString(title, " ")
	title = spaceRe.ReplaceAllString(title, " ")
	return strings.TrimSpace(title)
}

func extractTitle(name string, mediaType models.MediaType) string {
	title := normalizeSeparators(name)

	if mediaType == models.TypeMovie {
		title = cutBeforeYear(title)
	} else if mediaType == models.TypeShow {
		title = cutBeforeTVPattern(title)
	}

	return stripReleaseTags(title, true)
}

// ParseReleaseFilename extracts a clean title and year from a release filename.
func ParseReleaseFilename(raw string, mediaType models.MediaType) ParsedReleaseName {
	raw = strings.TrimSpace(raw)
	return ParsedReleaseName{
		Title:    extractTitle(raw, mediaType),
		Year:     extractYear(raw),
		Original: raw,
	}
}

// ReleaseDisplayTitle returns a human-readable title from a release filename.
func ReleaseDisplayTitle(raw string, mediaType models.MediaType) string {
	parsed := ParseReleaseFilename(raw, mediaType)
	if parsed.Title != "" {
		return parsed.Title
	}
	cleaned := StripReleaseTags(raw)
	if cleaned != "" {
		return cleaned
	}
	return strings.TrimSpace(raw)
}

// StripReleaseTags removes release noise without removing season/episode markers.
func StripReleaseTags(raw string) string {
	return stripReleaseTags(normalizeSeparators(raw), false)
}

// ExtraCleanSearchQuery applies a second-pass cleanup for TMDB search fallbacks.
func ExtraCleanSearchQuery(query string) string {
	cleaned := extraCleanRe.ReplaceAllString(query, " ")
	cleaned = spaceRe.ReplaceAllString(cleaned, " ")
	return strings.TrimSpace(cleaned)
}

// BuildTMDBSearchQueries returns deduplicated search queries (parsed title, extra-clean, first 3 words).
func BuildTMDBSearchQueries(parsed ParsedReleaseName) []string {
	seen := map[string]bool{}
	var queries []string

	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		queries = append(queries, s)
	}

	add(parsed.Title)
	if extra := ExtraCleanSearchQuery(parsed.Title); extra != parsed.Title {
		add(extra)
	}

	words := strings.Fields(parsed.Title)
	if len(words) > 3 {
		add(strings.Join(words[:3], " "))
	}

	for _, sep := range []string{" - ", " – ", " — ", ": ", " (", " ["} {
		if idx := strings.Index(parsed.Title, sep); idx > 0 {
			add(strings.TrimSpace(parsed.Title[:idx]))
		}
	}

	return queries
}
