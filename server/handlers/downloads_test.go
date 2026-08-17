package handlers

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

// uploadRequest builds the multipart request the admin UI sends.
func uploadRequest(t *testing.T, filename, version, payload string) *http.Request {
	t.Helper()
	body := &bytes.Buffer{}
	form := multipart.NewWriter(body)
	if version != "" {
		if err := form.WriteField("version", version); err != nil {
			t.Fatal(err)
		}
	}
	part, err := form.CreateFormFile("file", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte(payload)); err != nil {
		t.Fatal(err)
	}
	if err := form.Close(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/downloads", body)
	req.Header.Set("Content-Type", form.FormDataContentType())
	return req
}

func TestUploadDownloadReplacesThePlatformArtifact(t *testing.T) {
	dir := stageDownloads(t, "Onyx-0.9.0-windows.exe", "Onyx-1.0.0-macos.dmg")

	rec := httptest.NewRecorder()
	UploadDownload(rec, uploadRequest(t, "ProjectPlayer-Setup.exe", "1.4.0", "new-installer"), nil, 1)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}

	// The old Windows artifact is gone, the macOS one untouched.
	if _, err := os.Stat(filepath.Join(dir, "Onyx-0.9.0-windows.exe")); !os.IsNotExist(err) {
		t.Error("previous windows artifact still present")
	}
	if _, err := os.Stat(filepath.Join(dir, "Onyx-1.0.0-macos.dmg")); err != nil {
		t.Errorf("macos artifact disturbed: %v", err)
	}

	// Published under the staging script's naming, with the given version.
	content, err := os.ReadFile(filepath.Join(dir, "Onyx-1.4.0-windows.exe"))
	if err != nil {
		t.Fatalf("uploaded artifact missing: %v", err)
	}
	if string(content) != "new-installer" {
		t.Errorf("content = %q", content)
	}

	// No leftover temp file next to the artifacts.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".upload-") {
			t.Errorf("temp file left behind: %s", e.Name())
		}
	}
}

func TestUploadDownloadFallsBackToTheVersionInTheFileName(t *testing.T) {
	dir := stageDownloads(t)

	rec := httptest.NewRecorder()
	UploadDownload(rec, uploadRequest(t, "Onyx-2.1.0-android.apk", "", "apk"), nil, 1)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "Onyx-2.1.0-android.apk")); err != nil {
		t.Errorf("expected version read from the file name: %v", err)
	}
}

func TestUploadDownloadRejectsUnknownExtension(t *testing.T) {
	dir := stageDownloads(t)

	rec := httptest.NewRecorder()
	UploadDownload(rec, uploadRequest(t, "payload.sh", "1.0.0", "rm -rf /"), nil, 1)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("nothing should have been written, found %d entries", len(entries))
	}
}

func TestDeleteDownloadRemovesOnlyListedArtifacts(t *testing.T) {
	dir := stageDownloads(t, "Onyx-1.0.0-android.apk", "secrets.env")

	rec := httptest.NewRecorder()
	DeleteDownload(rec, httptest.NewRequest(http.MethodDelete, "/api/downloads/x", nil),
		httprouter.Params{{Key: "file", Value: "/Onyx-1.0.0-android.apk"}}, 1)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "Onyx-1.0.0-android.apk")); !os.IsNotExist(err) {
		t.Error("artifact not removed")
	}

	// Same guard as ServeDownload: anything the listing does not vouch for.
	for _, name := range []string{"secrets.env", "../../etc/passwd"} {
		rec := httptest.NewRecorder()
		DeleteDownload(rec, httptest.NewRequest(http.MethodDelete, "/api/downloads/x", nil),
			httprouter.Params{{Key: "file", Value: "/" + name}}, 1)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%q: status = %d, want 404", name, rec.Code)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "secrets.env")); err != nil {
		t.Errorf("unrelated file deleted: %v", err)
	}
}
