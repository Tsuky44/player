package handlers

// Client app downloads (APK / DMG / EXE).
//
// The binaries are baked into the Docker image at /app/downloads by
// publish-image.sh, which stages whatever the publishing host was able to build
// (macOS produces the DMG, Windows produces the EXE, both produce the APK) on
// top of the artifacts recovered from the previously published image. The
// directory is therefore the source of truth: no manifest file to keep in sync,
// the handler simply describes what is actually there.

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/julienschmidt/httprouter"
)

// DownloadArtifact is one installable file, as published to the web client.
type DownloadArtifact struct {
	Platform string `json:"platform"`
	Label    string `json:"label"`
	File     string `json:"file"`
	URL      string `json:"url"`
	Version  string `json:"version"`
	Size     int64  `json:"size"`
	// BuiltAt is the file's modification time (RFC3339). Docker preserves it
	// through COPY, so it really is the moment the artifact was produced.
	BuiltAt string `json:"built_at"`
}

// platformForExt maps an extension to the platform label shown in the UI, and
// doubles as the whitelist of what may be served: anything else in the folder
// is ignored rather than exposed.
var platformForExt = map[string]struct {
	platform string
	label    string
	// order sorts the list for the UI; lower comes first.
	order int
}{
	".exe": {"windows", "Windows (installeur)", 0},
	".zip": {"windows-portable", "Windows (portable)", 1},
	".dmg": {"macos", "macOS", 2},
	".apk": {"android", "Android (APK)", 3},
}

// versionInName pulls 1.0.0 out of "Onyx-1.0.0-macos.dmg". Artifacts staged by
// different hosts can carry different versions, which is exactly why the
// version is read per file instead of once for the whole release.
var versionInName = regexp.MustCompile(`(\d+\.\d+(?:\.\d+)?)`)

// DownloadsDir resolves where the artifacts live: DOWNLOADS_DIR when set, the
// container path otherwise, and ./downloads as a fallback so the feature also
// works when running the server straight from a checkout.
func DownloadsDir() string {
	if dir := strings.TrimSpace(os.Getenv("DOWNLOADS_DIR")); dir != "" {
		return dir
	}
	if info, err := os.Stat("/app/downloads"); err == nil && info.IsDir() {
		return "/app/downloads"
	}
	return "./downloads"
}

// listArtifacts scans the directory on every call. It is a handful of stat
// calls on a directory holding at most a few files, and it means an artifact
// dropped in through a volume mount shows up without a restart.
func listArtifacts() []DownloadArtifact {
	artifacts := []DownloadArtifact{}

	dir := DownloadsDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		// No directory at all (dev checkout, image built before this feature):
		// an empty list, never an error — the UI just hides the section.
		return artifacts
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		meta, known := platformForExt[strings.ToLower(filepath.Ext(entry.Name()))]
		if !known {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}

		version := ""
		if m := versionInName.FindStringSubmatch(entry.Name()); m != nil {
			version = m[1]
		}

		artifacts = append(artifacts, DownloadArtifact{
			Platform: meta.platform,
			Label:    meta.label,
			File:     entry.Name(),
			URL:      "/api/downloads/" + entry.Name(),
			Version:  version,
			Size:     info.Size(),
			BuiltAt:  info.ModTime().UTC().Format("2006-01-02T15:04:05Z"),
		})
	}

	sort.Slice(artifacts, func(i, j int) bool {
		oi := platformForExt[strings.ToLower(filepath.Ext(artifacts[i].File))].order
		oj := platformForExt[strings.ToLower(filepath.Ext(artifacts[j].File))].order
		if oi != oj {
			return oi < oj
		}
		return artifacts[i].File < artifacts[j].File
	})
	return artifacts
}

// ListDownloads publishes the available client apps.
//
// Unauthenticated on purpose: this is how a new user gets the app in the first
// place, and the response only reveals file names and sizes.
func ListDownloads(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")
	// The set changes only on a deploy, but a stale list would point at files
	// that no longer exist, so keep it short-lived.
	w.Header().Set("Cache-Control", "public, max-age=60")
	json.NewEncoder(w).Encode(map[string]any{
		"artifacts": listArtifacts(),
	})
}

// ServeDownload streams one artifact. The browser downloads it directly, so
// this has to stay unauthenticated too — an <a href> cannot carry a token.
func ServeDownload(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	// Only ever a name inside the downloads directory: Base strips any ../, and
	// the file must be one the listing already vouched for.
	name := filepath.Base(strings.TrimPrefix(ps.ByName("file"), "/"))

	var match *DownloadArtifact
	for _, a := range listArtifacts() {
		if a.File == name {
			artifact := a
			match = &artifact
			break
		}
	}
	if match == nil {
		http.Error(w, "download not found", http.StatusNotFound)
		return
	}

	path := filepath.Join(DownloadsDir(), match.File)
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "download not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, "download not readable", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="`+match.File+`"`)
	// ServeContent handles Range and If-Modified-Since, so an interrupted
	// download of a 100 MB APK resumes instead of restarting.
	http.ServeContent(w, r, match.File, info.ModTime(), f)
}
