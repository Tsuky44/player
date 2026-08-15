package indexer

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// Video containers we index. Kept close to Emby's list — a missing extension
// silently drops films from the library.
var videoExtensions = map[string]bool{
	".mp4": true, ".m4v": true, ".mkv": true, ".avi": true, ".mov": true,
	".wmv": true, ".flv": true, ".webm": true, ".mpg": true, ".mpeg": true,
	".mpe": true, ".m2v": true, ".mp2": true, ".ts": true, ".m2ts": true,
	".mts": true, ".vob": true, ".ogm": true, ".ogv": true, ".divx": true,
	".rm": true, ".rmvb": true, ".asf": true, ".3gp": true, ".3g2": true,
	".f4v": true, ".mpv": true, ".qt": true, ".dv": true,
}

// Disc images hold a film but cannot be streamed in direct play. They are
// reported instead of being indexed as unplayable entries.
var unplayableExtensions = map[string]bool{
	".iso": true, ".img": true, ".bin": true, ".nrg": true, ".mdf": true,
}

// IsUnplayableImageFile reports whether a path is a disc image.
func IsUnplayableImageFile(path string) bool {
	return unplayableExtensions[strings.ToLower(filepath.Ext(path))]
}

// IsVideoFile reports whether a path has a supported video extension.
func IsVideoFile(path string) bool {
	return videoExtensions[strings.ToLower(filepath.Ext(path))]
}

// Directories created by NAS/OS tooling that never hold library content.
var junkDirNames = map[string]bool{
	"@eadir": true, ".appledouble": true, "#recycle": true, "$recycle.bin": true,
	"lost+found": true, ".trashes": true, ".trash": true, "system volume information": true,
	".@__thumb": true, ".git": true, "@recycle": true, ".stfolder": true, ".stversions": true,
}

// Folders whose videos are bonus content, not library items (Emby's extra dirs).
var extrasDirNames = map[string]bool{
	"extras": true, "extra": true, "featurettes": true, "featurette": true,
	"behind the scenes": true, "deleted scenes": true, "interviews": true,
	"scenes": true, "shorts": true, "trailers": true, "trailer": true,
	"samples": true, "sample": true, "bonus": true, "bonus disc": true,
	"making of": true, "other": true, "others": true, "theme-music": true,
	"backdrops": true, "subs": true, "subtitles": true, "sous-titres": true,
	"proof": true, "screens": true, "screenshots": true,
}

// Emby marks bonus content with a "-marker" suffix ("Film-trailer.mkv").
var extraSuffixMarkers = map[string]bool{
	"trailer": true, "sample": true, "featurette": true, "behindthescenes": true,
	"deleted": true, "deletedscene": true, "deletedscenes": true, "interview": true,
	"interviews": true, "scene": true, "short": true, "clip": true, "other": true,
	"extra": true, "extras": true, "theme": true, "bandeannonce": true,
}

// Release samples are also named "…1080p-GROUP.sample.mkv".
var extraLastTokenMarkers = map[string]bool{
	"sample": true, "trailer": true, "echantillon": true,
}

// IsJunkDirName reports whether a directory should never be descended into.
func IsJunkDirName(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if junkDirNames[lower] {
		return true
	}
	// Hidden folders (but not "." itself, which is the walk root).
	return len(lower) > 1 && strings.HasPrefix(lower, ".")
}

// IsExtrasDirName reports whether a directory holds bonus content only.
func IsExtrasDirName(name string) bool {
	return extrasDirNames[strings.ToLower(strings.TrimSpace(name))]
}

// IsExtraFileName reports whether a file is a sample/trailer/featurette rather
// than a library item. Matching is anchored at the end of the name so a film
// actually called "Trailer Park Boys" is still indexed.
func IsExtraFileName(name string) bool {
	base := strings.ToLower(strings.TrimSuffix(filepath.Base(name), filepath.Ext(name)))
	if strings.HasPrefix(base, "._") {
		return true // AppleDouble sidecar
	}
	base = strings.TrimSpace(base)
	if base == "" {
		return false
	}

	// "-trailer", "-sample2", "-featurette" suffix (Emby convention).
	if idx := strings.LastIndexAny(base, "-"); idx >= 0 && idx < len(base)-1 {
		suffix := strings.TrimRight(strings.TrimSpace(base[idx+1:]), "0123456789 ")
		if extraSuffixMarkers[strings.ReplaceAll(suffix, " ", "")] {
			return true
		}
	}

	fields := strings.Fields(strings.NewReplacer(".", " ", "_", " ", "-", " ").Replace(base))
	if len(fields) == 0 {
		return false
	}
	last := strings.TrimRight(fields[len(fields)-1], "0123456789")
	if extraLastTokenMarkers[last] {
		return true
	}
	return len(fields) == 1 && extraSuffixMarkers[fields[0]]
}

var multipartRe = regexp.MustCompile(`(?i)[\s._-]*(?:\(|\[)?\s*(?:cd|dvd|disc|disk|part|pt|partie)\s*[\s._-]?(\d{1,2})\s*(?:of|sur|/)?\s*\d{0,2}\s*(?:\)|\])?\s*$`)

// MultipartKey splits "Movie.cd1" / "Movie (part 2)" into a shared key and the
// part number. Multi-part rips are one film, not several.
func MultipartKey(fileBase string) (key string, part int, ok bool) {
	base := fileBase
	if IsVideoFile(base) {
		// Only a real container extension is dropped: ".cd1" and ".1080p" look
		// like extensions to filepath.Ext but are part of the name.
		base = strings.TrimSuffix(base, filepath.Ext(base))
	}
	m := multipartRe.FindStringSubmatch(base)
	if len(m) != 2 {
		return base, 0, false
	}
	part, err := strconv.Atoi(m[1])
	if err != nil || part <= 0 {
		return base, 0, false
	}
	trimmed := strings.TrimSpace(multipartRe.ReplaceAllString(base, ""))
	if trimmed == "" {
		return base, 0, false
	}
	return trimmed, part, true
}

// IsSecondaryMultipartFile reports whether this file is a continuation part
// (cd2, part 3…) whose first part carries the identity.
func IsSecondaryMultipartFile(fileBase string) bool {
	_, part, ok := MultipartKey(fileBase)
	return ok && part > 1
}

var (
	movieDirCountCache   = map[string]int{}
	movieDirCountCacheMu sync.Mutex
)

// ResetDirScanCache clears the per-directory movie counts. Called when a scan
// starts so newly added files are seen.
func ResetDirScanCache() {
	movieDirCountCacheMu.Lock()
	movieDirCountCache = map[string]int{}
	movieDirCountCacheMu.Unlock()
}

// CountDistinctMoviesInDir counts how many different films a directory holds
// directly: samples/trailers are ignored and multi-part rips count once. A
// count above 1 means the folder groups films instead of naming one.
func CountDistinctMoviesInDir(dir string) int {
	dir = filepath.Clean(dir)

	movieDirCountCacheMu.Lock()
	if n, ok := movieDirCountCache[dir]; ok {
		movieDirCountCacheMu.Unlock()
		return n
	}
	movieDirCountCacheMu.Unlock()

	entries, err := os.ReadDir(dir)
	if err != nil {
		// Unreadable directory: assume a single movie so the folder can still name it.
		return 1
	}

	distinct := map[string]bool{}
	for _, entry := range entries {
		if entry.IsDir() || !IsVideoFile(entry.Name()) || IsExtraFileName(entry.Name()) {
			continue
		}
		base := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
		key, _, _ := MultipartKey(base)
		distinct[strings.ToLower(key)] = true
	}
	count := len(distinct)

	movieDirCountCacheMu.Lock()
	if len(movieDirCountCache) > 20000 {
		movieDirCountCache = map[string]int{}
	}
	movieDirCountCache[dir] = count
	movieDirCountCacheMu.Unlock()

	return count
}
