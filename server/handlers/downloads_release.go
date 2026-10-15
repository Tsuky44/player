package handlers

// The installers of the server's own version, taken from its GitHub Release
// (ADR-0062). downloads.go lists and serves; this file is the bridge to
// releasedl.

import (
	"context"
	"log"
	"net/http"
	"path/filepath"
	"strconv"

	"project-player/server/releasedl"
)

// releaseSource is set once at startup. Nil (the zero value) means the server
// offers only what sits in the downloads directory.
var releaseSource *releasedl.Source

// SetReleaseSource installs the source of the Release installers.
func SetReleaseSource(s *releasedl.Source) {
	releaseSource = s
}

// releaseCandidates are the Release assets that look like installers; the
// platformForExt whitelist drops checksums, notes and anything else attached.
func releaseCandidates(ctx context.Context) []candidate {
	var found []candidate
	for _, asset := range releaseSource.Assets(ctx) {
		c, ok := newCandidate(asset.Name, asset.Size, asset.UpdatedAt)
		if !ok {
			continue
		}
		c.artifact.fromRelease = true
		found = append(found, c)
	}
	return found
}

// downloadPath says where the bytes of an artifact are, fetching a Release
// asset on its first request. It answers the request itself when it cannot
// hand a path back.
func downloadPath(w http.ResponseWriter, r *http.Request, a DownloadArtifact) (string, bool) {
	if !a.fromRelease {
		return filepath.Join(DownloadsDir(), a.File), true
	}
	asset, ok := releaseSource.Find(r.Context(), a.File)
	if !ok {
		http.Error(w, "download not found", http.StatusNotFound)
		return "", false
	}

	// A HEAD (a link preview, a download manager sizing the file) must not make
	// the server pull 150 MB. Say what the file is, and fetch it for the GET.
	if _, cached := releaseSource.Cached(asset); !cached && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="`+a.File+`"`)
		w.Header().Set("Content-Length", strconv.FormatInt(asset.Size, 10))
		w.WriteHeader(http.StatusOK)
		return "", false
	}

	path, err := releaseSource.Ensure(r.Context(), asset)
	if err != nil {
		log.Printf("ServeDownload: %v", err)
		http.Error(w, "download unavailable", http.StatusBadGateway)
		return "", false
	}
	return path, true
}
