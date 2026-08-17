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
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

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

// ---------------------------------------------------------------------------
// Administration: replacing the artifacts by hand.
//
// The normal path is a publish, which bakes the installers into the image. That
// requires a build machine for every platform, so the admin account can also
// drop a file in directly — a locally built EXE, a signed DMG rebuilt by hand —
// and it takes effect immediately, listArtifacts() reading the directory on
// every call.
// ---------------------------------------------------------------------------

// maxUploadBytes caps an uploaded installer. Well above the ~150 MB artifacts
// the project produces, low enough that a mistake cannot fill the disk.
const maxUploadBytes = 2 << 30 // 2 GiB

// errUploadTooLarge is what the size guard reports through the copy.
var errUploadTooLarge = errors.New("upload too large")

// artifactName builds the published name for a platform, matching what
// scripts/stage-downloads.ps1 produces so both paths stay interchangeable.
func artifactName(version, platform, ext string) string {
	return fmt.Sprintf("Onyx-%s-%s%s", version, platform, ext)
}

// UploadDownload replaces (or adds) the installer for one platform.
//
// multipart/form-data with a `file` part; an optional `version` part overrides
// the version read from the uploaded file name. The platform is deduced from
// the extension, which is also the whitelist: the same map that decides what
// may be served decides what may be uploaded.
func UploadDownload(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	// The server's ReadTimeout covers the whole request body, and 150 MB over a
	// home upstream takes far longer than 30 s. Drop the read deadline for this
	// request only; the transfer stays bounded by maxUploadBytes.
	if err := http.NewResponseController(w).SetReadDeadline(time.Time{}); err != nil {
		log.Printf("UploadDownload: cannot lift read deadline: %v", err)
	}

	reader, err := r.MultipartReader()
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Envoi multipart attendu")
		return
	}

	dir := DownloadsDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Printf("UploadDownload: cannot create %s: %v", dir, err)
		writeJSONError(w, http.StatusInternalServerError, "Dossier de téléchargements inaccessible")
		return
	}

	var (
		tmpPath      string
		ext          string
		originalName string
		version      string
	)
	// The temp file is written next to the artifacts so the final rename stays
	// on one filesystem, and is removed on every failure path below.
	defer func() {
		if tmpPath != "" {
			os.Remove(tmpPath)
		}
	}()

	for {
		part, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "Envoi interrompu")
			return
		}

		switch part.FormName() {
		case "version":
			// Small text field: a bounded read, never the whole body.
			raw, _ := io.ReadAll(io.LimitReader(part, 64))
			version = strings.TrimSpace(string(raw))
		case "file":
			if tmpPath != "" {
				writeJSONError(w, http.StatusBadRequest, "Un seul fichier à la fois")
				return
			}
			originalName = filepath.Base(part.FileName())
			ext = strings.ToLower(filepath.Ext(originalName))
			if _, known := platformForExt[ext]; !known {
				writeJSONError(w, http.StatusBadRequest, "Extension non prise en charge (.exe, .zip, .dmg, .apk)")
				return
			}

			// `.tmp`, never the real extension: listArtifacts() would otherwise
			// pick the half-written file up as the platform's artifact — and the
			// replace sweep below would delete it just before the rename.
			tmp, err := os.CreateTemp(dir, ".upload-*.tmp")
			if err != nil {
				log.Printf("UploadDownload: temp file failed: %v", err)
				writeJSONError(w, http.StatusInternalServerError, "Écriture impossible")
				return
			}
			tmpPath = tmp.Name()

			// LimitReader + one extra byte: a file exactly at the cap passes,
			// anything beyond is refused without ever landing on disk whole.
			written, copyErr := io.Copy(tmp, io.LimitReader(part, maxUploadBytes+1))
			closeErr := tmp.Close()
			if copyErr == nil && written > maxUploadBytes {
				copyErr = errUploadTooLarge
			}
			if copyErr == nil {
				copyErr = closeErr
			}
			if copyErr != nil {
				if errors.Is(copyErr, errUploadTooLarge) {
					writeJSONError(w, http.StatusRequestEntityTooLarge, "Fichier trop volumineux (2 Go maximum)")
					return
				}
				log.Printf("UploadDownload: copy failed: %v", copyErr)
				writeJSONError(w, http.StatusInternalServerError, "Écriture impossible")
				return
			}
			if written == 0 {
				writeJSONError(w, http.StatusBadRequest, "Fichier vide")
				return
			}
		}
		part.Close()
	}

	if tmpPath == "" {
		writeJSONError(w, http.StatusBadRequest, "Aucun fichier reçu")
		return
	}

	meta := platformForExt[ext]
	if version == "" {
		if m := versionInName.FindStringSubmatch(originalName); m != nil {
			version = m[1]
		}
	}
	if version == "" {
		version = "1.0.0"
	}
	if !versionInName.MatchString(version) {
		writeJSONError(w, http.StatusBadRequest, "Version invalide (ex. 1.2.0)")
		return
	}

	// One artifact per platform: drop the previous one whatever its version,
	// exactly like the staging script does.
	for _, existing := range listArtifacts() {
		if existing.Platform == meta.platform {
			os.Remove(filepath.Join(dir, existing.File))
		}
	}

	finalPath := filepath.Join(dir, artifactName(version, meta.platform, ext))
	if err := os.Rename(tmpPath, finalPath); err != nil {
		log.Printf("UploadDownload: rename failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Publication impossible")
		return
	}
	tmpPath = "" // renamed: nothing left to clean up
	if err := os.Chmod(finalPath, 0o644); err != nil {
		log.Printf("UploadDownload: chmod %s: %v", finalPath, err)
	}

	json.NewEncoder(w).Encode(map[string]any{
		"artifacts": listArtifacts(),
	})
}

// DeleteDownload removes one published artifact (DELETE /api/downloads/:file).
func DeleteDownload(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	// Same guard as ServeDownload: a bare name, and only one the listing
	// already vouched for.
	name := filepath.Base(strings.TrimPrefix(ps.ByName("file"), "/"))

	found := false
	for _, a := range listArtifacts() {
		if a.File == name {
			found = true
			break
		}
	}
	if !found {
		writeJSONError(w, http.StatusNotFound, "Installeur introuvable")
		return
	}

	if err := os.Remove(filepath.Join(DownloadsDir(), name)); err != nil {
		log.Printf("DeleteDownload: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Suppression impossible")
		return
	}

	json.NewEncoder(w).Encode(map[string]any{
		"artifacts": listArtifacts(),
	})
}
