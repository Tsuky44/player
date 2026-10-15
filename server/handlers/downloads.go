package handlers

// Client app downloads (APK / DMG / EXE).
//
// The installers are no longer baked into the Docker image (ADR-0062): they are
// the assets of the GitHub Release that carries the server's own version, see
// releasedl. A file dropped by hand in the downloads directory (the admin
// upload below, a volume mount) still wins over the Release for its platform.
// Either way no manifest file is kept: the handler describes what is actually
// there.

import (
	"context"
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
	"strconv"
	"strings"
	"time"

	"github.com/julienschmidt/httprouter"

	"project-player/server/installorigin"
	"project-player/server/streaming"
)

// DownloadArtifact is one installable file, as published to the web client.
type DownloadArtifact struct {
	Platform string `json:"platform"`
	Label    string `json:"label"`
	File     string `json:"file"`
	URL      string `json:"url"`
	Version  string `json:"version"`
	Size     int64  `json:"size"`
	// BuiltAt is the file's modification time (RFC3339), or the moment the
	// Release asset was uploaded: when the artifact was produced.
	BuiltAt string `json:"built_at"`

	// fromRelease: the file is a Release asset, fetched on first download
	// rather than sitting in the downloads directory.
	fromRelease bool
}

// platformForExt maps an extension to the platform label shown in the UI, and
// doubles as the whitelist of what may be served: anything else in the folder
// is ignored rather than exposed.
var platformForExt = map[string]artifactKind{
	".exe": {"windows", "Windows (installeur)", 0},
	".zip": {"windows-portable", "Windows (portable)", 1},
	".dmg": {"macos", "macOS", 2},
	".apk": {"android", "Android (APK)", 3},
	".ipa": {"ios", "iOS (IPA)", 4},
}

// artifactKind is what the listing says about one file.
type artifactKind struct {
	platform string
	label    string
	// order sorts the list for the UI; lower comes first.
	order int
}

// tvosArtifact is the Apple TV build. It is an .ipa like the iPhone one, and
// only its name tells them apart — without this the two would compete for the
// single "ios" slot, and whichever won would hide the other.
var tvosArtifact = artifactKind{"tvos", "Apple TV (IPA)", 5}

// artifactKindFor classifies a file by name: its extension, and for an .ipa
// the `-tvos` suffix that artifactName gives the Apple TV build.
func artifactKindFor(name string) (artifactKind, bool) {
	ext := strings.ToLower(filepath.Ext(name))
	kind, known := platformForExt[ext]
	if known && ext == ".ipa" && strings.HasSuffix(strings.ToLower(name), "-tvos.ipa") {
		return tvosArtifact, true
	}
	return kind, known
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

// candidate is one file competing for its platform's slot in the listing.
type candidate struct {
	artifact DownloadArtifact
	modTime  time.Time
}

// newCandidate describes a file by its name, or false when it is not an
// installer (platformForExt is the whitelist).
func newCandidate(name string, size int64, modTime time.Time) (candidate, bool) {
	meta, known := artifactKindFor(name)
	if !known {
		return candidate{}, false
	}
	version := ""
	if m := versionInName.FindStringSubmatch(name); m != nil {
		version = m[1]
	}
	return candidate{
		artifact: DownloadArtifact{
			Platform: meta.platform,
			Label:    meta.label,
			File:     name,
			URL:      "/api/downloads/" + name,
			Version:  version,
			Size:     size,
			BuiltAt:  modTime.UTC().Format("2006-01-02T15:04:05Z"),
		},
		modTime: modTime,
	}, true
}

// localCandidates scans the downloads directory on every call. It is a handful
// of stat calls on a directory holding at most a few files, and it means an
// artifact dropped in through a volume mount shows up without a restart.
func localCandidates() []candidate {
	entries, err := os.ReadDir(DownloadsDir())
	if err != nil {
		// No directory at all (dev checkout, nothing uploaded): no candidates,
		// never an error.
		return nil
	}
	var found []candidate
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if c, ok := newCandidate(entry.Name(), info.Size(), info.ModTime()); ok {
			found = append(found, c)
		}
	}
	return found
}

// listLocalArtifacts is what sits in the downloads directory, and only that:
// the files the admin can replace or delete.
func listLocalArtifacts() []DownloadArtifact {
	return bestPerPlatform(localCandidates())
}

// listArtifacts is what the server offers: the files of the downloads
// directory, completed by the Release of the server's own version for every
// platform the directory leaves empty (ADR-0062).
func listArtifacts(ctx context.Context) []DownloadArtifact {
	all := localCandidates()
	have := map[string]bool{}
	for _, c := range all {
		have[c.artifact.Platform] = true
	}
	for _, c := range releaseCandidates(ctx) {
		if !have[c.artifact.Platform] {
			all = append(all, c)
		}
	}
	return bestPerPlatform(all)
}

// bestPerPlatform keeps exactly one entry per platform: `.exe` and `.zip` both
// map "windows" to two different extensions (installer vs portable), but
// nothing stops two files of the *same* extension from sitting in the directory
// at once — a build staged by hand, an interrupted publish, a leftover.
// Silently listing both used to mean the client compared itself against
// whichever sorted first alphabetically, which is not necessarily the newest:
// "Onyx-0.9.0-windows.exe" comes before "Onyx-1.0.0-windows.exe", so a stale
// lower-numbered leftover could shadow the real update. Keeping the highest
// version per platform (or, when a name fails to parse, the most recently
// written file) makes the listing agree with the version compare a client does
// anyway.
func bestPerPlatform(candidates []candidate) []DownloadArtifact {
	best := map[string]candidate{}
	for _, next := range candidates {
		platform := next.artifact.Platform
		current, exists := best[platform]
		if !exists {
			best[platform] = next
			continue
		}
		if cmp := compareVersions(next.artifact.Version, current.artifact.Version); cmp > 0 {
			best[platform] = next
		} else if cmp == 0 && next.modTime.After(current.modTime) {
			best[platform] = next
		}
	}

	artifacts := make([]DownloadArtifact, 0, len(best))
	for _, c := range best {
		artifacts = append(artifacts, c.artifact)
	}

	sort.Slice(artifacts, func(i, j int) bool {
		ki, _ := artifactKindFor(artifacts[i].File)
		kj, _ := artifactKindFor(artifacts[j].File)
		oi, oj := ki.order, kj.order
		if oi != oj {
			return oi < oj
		}
		return artifacts[i].File < artifacts[j].File
	})
	return artifacts
}

// compareVersions orders two dot-separated numeric versions ("1.2.3"),
// treating missing trailing components as 0. A version that fails to parse
// (empty, non-numeric) sorts below one that does, so a clean name always beats
// a mangled one instead of an arbitrary string comparison deciding.
func compareVersions(a, b string) int {
	pa, oka := versionParts(a)
	pb, okb := versionParts(b)
	if !oka || !okb {
		if oka == okb {
			return 0
		}
		if oka {
			return 1
		}
		return -1
	}

	length := len(pa)
	if len(pb) > length {
		length = len(pb)
	}
	for i := 0; i < length; i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func versionParts(v string) ([]int, bool) {
	if v == "" {
		return nil, false
	}
	segments := strings.Split(v, ".")
	parts := make([]int, 0, len(segments))
	for _, s := range segments {
		n, err := strconv.Atoi(s)
		if err != nil {
			return nil, false
		}
		parts = append(parts, n)
	}
	return parts, true
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
	json.NewEncoder(w).Encode(artifactsResponse{Artifacts: listArtifacts(r.Context())})
}

// ServeDownload streams one artifact. The browser downloads it directly, so
// this has to stay unauthenticated too — an <a href> cannot carry a token.
func ServeDownload(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	// Only ever a name inside the downloads directory: Base strips any ../, and
	// the file must be one the listing already vouched for.
	name := filepath.Base(strings.TrimPrefix(ps.ByName("file"), "/"))

	var match *DownloadArtifact
	for _, a := range listArtifacts(r.Context()) {
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

	path, ok := downloadPath(w, r, *match)
	if !ok {
		return
	}
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

	// L'APK et l'IPA partent avec l'adresse d'où on les télécharge, pour que
	// l'app s'ouvre sur ce serveur (ADR-0042). C'est l'adresse vue par le
	// navigateur : derrière un reverse proxy, celle du proxy.
	content, _ := installorigin.Stamp(f, info.Size(), match.File, streaming.BaseURL(r)+r.URL.Path)

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="`+match.File+`"`)
	// ServeContent handles Range and If-Modified-Since, so an interrupted
	// download of a 100 MB APK resumes instead of restarting.
	http.ServeContent(w, r, match.File, info.ModTime(), content)
}

// ---------------------------------------------------------------------------
// Administration: replacing the artifacts by hand.
//
// The normal path is the Release of the server's version (ADR-0062), but the
// admin account can also drop a file in directly — a locally built EXE, a signed
// DMG rebuilt by hand — and it takes effect immediately, localCandidates()
// reading the directory on every call. It wins over the Release for its
// platform.
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
				writeJSONError(w, http.StatusBadRequest, "Extension non prise en charge (.exe, .zip, .dmg, .apk, .ipa)")
				return
			}

			// `.tmp`, never the real extension: localCandidates() would otherwise
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

	meta, _ := artifactKindFor(originalName)
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
	for _, existing := range listLocalArtifacts() {
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

	json.NewEncoder(w).Encode(artifactsResponse{Artifacts: listArtifacts(r.Context())})
}

// DeleteDownload removes one published artifact (DELETE /api/downloads/:file).
func DeleteDownload(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	// Same guard as ServeDownload: a bare name, and only one the listing
	// already vouched for.
	name := filepath.Base(strings.TrimPrefix(ps.ByName("file"), "/"))

	found := false
	for _, a := range listLocalArtifacts() {
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

	json.NewEncoder(w).Encode(artifactsResponse{Artifacts: listArtifacts(r.Context())})
}
