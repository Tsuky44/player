package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/julienschmidt/httprouter"
)

// stageDownloads points DownloadsDir at a temp folder holding the given files.
func stageDownloads(t *testing.T, names ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("payload-"+name), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	t.Setenv("DOWNLOADS_DIR", dir)
	return dir
}

func TestListDownloadsDescribesKnownArtifacts(t *testing.T) {
	stageDownloads(t,
		"Onyx-1.0.0-android.apk",
		"Onyx-0.9.0-windows.exe",
		"Onyx-1.0.0-macos.dmg",
		".gitkeep",
		"notes.txt",
	)

	rec := httptest.NewRecorder()
	ListDownloads(rec, httptest.NewRequest(http.MethodGet, "/api/downloads", nil), nil)

	var body struct {
		Artifacts []DownloadArtifact `json:"artifacts"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if len(body.Artifacts) != 3 {
		t.Fatalf("expected the 3 installable files, got %d: %+v", len(body.Artifacts), body.Artifacts)
	}

	// Windows first, then macOS, then Android — the order the UI renders.
	wantPlatforms := []string{"windows", "macos", "android"}
	for i, want := range wantPlatforms {
		if body.Artifacts[i].Platform != want {
			t.Errorf("artifact %d: platform = %q, want %q", i, body.Artifacts[i].Platform, want)
		}
	}

	// The version is read per file: a platform can lag a release behind.
	if got := body.Artifacts[0].Version; got != "0.9.0" {
		t.Errorf("windows version = %q, want 0.9.0", got)
	}
	if got := body.Artifacts[0].URL; got != "/api/downloads/Onyx-0.9.0-windows.exe" {
		t.Errorf("windows url = %q", got)
	}
	if body.Artifacts[0].Size == 0 {
		t.Error("size not reported")
	}
}

// A leftover build from before the staging script's own cleanup, or one staged
// by hand, can leave two files for the same platform. The listing must not
// hand out whichever sorts first alphabetically — that let a stale, lower
// version shadow a real update.
func TestListDownloadsKeepsTheHighestVersionPerPlatform(t *testing.T) {
	stageDownloads(t,
		"Onyx-0.1.3-windows.exe",
		"Onyx-1.0.0-windows.exe",
	)

	rec := httptest.NewRecorder()
	ListDownloads(rec, httptest.NewRequest(http.MethodGet, "/api/downloads", nil), nil)

	var body struct {
		Artifacts []DownloadArtifact `json:"artifacts"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if len(body.Artifacts) != 1 {
		t.Fatalf("expected one windows artifact, got %d: %+v", len(body.Artifacts), body.Artifacts)
	}
	if got := body.Artifacts[0].Version; got != "1.0.0" {
		t.Errorf("version = %q, want the higher 1.0.0", got)
	}
	if got := body.Artifacts[0].File; got != "Onyx-1.0.0-windows.exe" {
		t.Errorf("file = %q, want the higher version's file", got)
	}
}

func TestServeDownloadSendsFileAsAttachment(t *testing.T) {
	stageDownloads(t, "Onyx-1.0.0-android.apk")

	rec := httptest.NewRecorder()
	ServeDownload(rec, httptest.NewRequest(http.MethodGet, "/api/downloads/Onyx-1.0.0-android.apk", nil),
		httprouter.Params{{Key: "file", Value: "/Onyx-1.0.0-android.apk"}})

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Disposition"); got != `attachment; filename="Onyx-1.0.0-android.apk"` {
		t.Errorf("Content-Disposition = %q", got)
	}
	if rec.Body.String() != "payload-Onyx-1.0.0-android.apk" {
		t.Errorf("body = %q", rec.Body.String())
	}
}

func TestServeDownloadRefusesAnythingNotListed(t *testing.T) {
	dir := stageDownloads(t, "Onyx-1.0.0-android.apk")
	// A secret sitting next to the artifacts, and one outside the directory.
	if err := os.WriteFile(filepath.Join(dir, "secrets.env"), []byte("TOKEN=1"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, name := range []string{"secrets.env", "../../etc/passwd", "..%2Fsecrets.env", ""} {
		rec := httptest.NewRecorder()
		ServeDownload(rec, httptest.NewRequest(http.MethodGet, "/api/downloads/x", nil),
			httprouter.Params{{Key: "file", Value: "/" + name}})
		if rec.Code != http.StatusNotFound {
			t.Errorf("%q: status = %d, want 404", name, rec.Code)
		}
	}
}

func TestListDownloadsOnMissingDirectory(t *testing.T) {
	t.Setenv("DOWNLOADS_DIR", filepath.Join(t.TempDir(), "nope"))

	rec := httptest.NewRecorder()
	ListDownloads(rec, httptest.NewRequest(http.MethodGet, "/api/downloads", nil), nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Body.String(); got != "{\"artifacts\":[]}\n" {
		t.Errorf("body = %q, want an empty list", got)
	}
}

// The iPhone and Apple TV builds are both .ipa files. Sharing one platform slot
// meant only one of them was ever listed.
func TestListDownloadsKeepsTheAppleTVBuildApartFromIOS(t *testing.T) {
	stageDownloads(t,
		"Onyx-1.2.0-ios.ipa",
		"Onyx-1.2.0-tvos.ipa",
	)

	rec := httptest.NewRecorder()
	ListDownloads(rec, httptest.NewRequest(http.MethodGet, "/api/downloads", nil), nil)

	var body struct {
		Artifacts []DownloadArtifact `json:"artifacts"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if len(body.Artifacts) != 2 {
		t.Fatalf("expected both .ipa files, got %d: %+v", len(body.Artifacts), body.Artifacts)
	}
	if got := body.Artifacts[0]; got.Platform != "ios" || got.File != "Onyx-1.2.0-ios.ipa" {
		t.Errorf("first artifact = %+v, want the iOS build", got)
	}
	if got := body.Artifacts[1]; got.Platform != "tvos" || got.Label != "Apple TV (IPA)" {
		t.Errorf("second artifact = %+v, want the Apple TV build", got)
	}
}
