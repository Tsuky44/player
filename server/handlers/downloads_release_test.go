package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/julienschmidt/httprouter"

	"project-player/server/releasedl"
)

// useRelease installs a Release source backed by a fake GitHub holding the
// given files under tag v<version>, and counts the file downloads.
func useRelease(t *testing.T, version string, files ...string) *atomic.Int32 {
	t.Helper()
	var fileHits atomic.Int32
	var server *httptest.Server
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/Tsuky44/player/releases/", func(w http.ResponseWriter, r *http.Request) {
		type asset struct {
			Name string `json:"name"`
			Size int64  `json:"size"`
			URL  string `json:"browser_download_url"`
		}
		body := struct {
			Tag    string  `json:"tag_name"`
			Assets []asset `json:"assets"`
		}{Tag: "v" + version}
		for _, name := range files {
			body.Assets = append(body.Assets, asset{name, int64(len("payload-" + name)), server.URL + "/files/" + name})
		}
		_ = json.NewEncoder(w).Encode(body)
	})
	mux.HandleFunc("/files/", func(w http.ResponseWriter, r *http.Request) {
		fileHits.Add(1)
		_, _ = w.Write([]byte("payload-" + filepath.Base(r.URL.Path)))
	})
	server = httptest.NewServer(mux)
	t.Cleanup(server.Close)

	SetReleaseSource(releasedl.New(releasedl.Config{Version: version, APIBase: server.URL, CacheDir: t.TempDir()}))
	t.Cleanup(func() { SetReleaseSource(nil) })
	return &fileHits
}

func listedFiles(t *testing.T) []DownloadArtifact {
	t.Helper()
	rec := httptest.NewRecorder()
	ListDownloads(rec, httptest.NewRequest(http.MethodGet, "/api/downloads", nil), nil)
	var body struct {
		Artifacts []DownloadArtifact `json:"artifacts"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return body.Artifacts
}

func TestListDownloadsOffersTheReleaseOfTheServerVersion(t *testing.T) {
	stageDownloads(t)
	useRelease(t, "1.2.0",
		"Onyx-1.2.0-windows.exe",
		"Onyx-1.2.0-android.apk",
		"Onyx-1.2.0-android.apk.sha256", // not an installer
	)

	got := listedFiles(t)
	if len(got) != 2 {
		t.Fatalf("expected the 2 installers of the Release, got %+v", got)
	}
	if got[0].Platform != "windows" || got[1].Platform != "android" {
		t.Errorf("platforms = %q, %q", got[0].Platform, got[1].Platform)
	}
	if got[1].Version != "1.2.0" || got[1].URL != "/api/downloads/Onyx-1.2.0-android.apk" {
		t.Errorf("android entry = %+v", got[1])
	}
}

// What the admin dropped in by hand is a deliberate choice: it wins over the
// Release for its platform, and the Release still fills the others.
func TestLocalInstallerShadowsTheReleaseForItsPlatform(t *testing.T) {
	stageDownloads(t, "Onyx-9.9.9-windows.exe")
	useRelease(t, "1.2.0", "Onyx-1.2.0-windows.exe", "Onyx-1.2.0-android.apk")

	got := listedFiles(t)
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	if got[0].File != "Onyx-9.9.9-windows.exe" {
		t.Errorf("windows = %q, want the local file", got[0].File)
	}
	if got[1].File != "Onyx-1.2.0-android.apk" {
		t.Errorf("android = %q, want the Release one", got[1].File)
	}
}

func TestServeDownloadFetchesAReleaseInstallerOnFirstRequestOnly(t *testing.T) {
	stageDownloads(t)
	fileHits := useRelease(t, "1.2.0", "Onyx-1.2.0-windows.exe")
	params := httprouter.Params{{Key: "file", Value: "Onyx-1.2.0-windows.exe"}}

	// HEAD says what the file is without making the server pull it.
	head := httptest.NewRecorder()
	ServeDownload(head, httptest.NewRequest(http.MethodHead, "/api/downloads/Onyx-1.2.0-windows.exe", nil), params)
	if head.Code != http.StatusOK || head.Header().Get("Content-Length") == "" {
		t.Fatalf("HEAD = %d, headers %v", head.Code, head.Header())
	}
	if hits := fileHits.Load(); hits != 0 {
		t.Fatalf("HEAD downloaded the file (%d fetches)", hits)
	}

	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		ServeDownload(rec, httptest.NewRequest(http.MethodGet, "/api/downloads/Onyx-1.2.0-windows.exe", nil), params)
		if rec.Code != http.StatusOK || rec.Body.String() != "payload-Onyx-1.2.0-windows.exe" {
			t.Fatalf("GET %d = %d %q", i, rec.Code, rec.Body.String())
		}
	}
	if hits := fileHits.Load(); hits != 1 {
		t.Errorf("the installer was fetched %d times, want 1", hits)
	}
}

func TestServeDownloadRefusesANameOutsideTheRelease(t *testing.T) {
	stageDownloads(t)
	useRelease(t, "1.2.0", "Onyx-1.2.0-windows.exe")

	rec := httptest.NewRecorder()
	ServeDownload(rec, httptest.NewRequest(http.MethodGet, "/api/downloads/Onyx-1.1.0-windows.exe", nil),
		httprouter.Params{{Key: "file", Value: "Onyx-1.1.0-windows.exe"}})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("an installer of another version answered %d, want 404", rec.Code)
	}
}
