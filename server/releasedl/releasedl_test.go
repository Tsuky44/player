package releasedl

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// fakeGitHub répond comme l'API des Releases : les Releases connues par leur
// tag, plus `latest`, et les fichiers sous /files/.
type fakeGitHub struct {
	server    *httptest.Server
	releases  map[string][]string // tag -> noms des fichiers
	latest    string
	apiHits   atomic.Int32
	fileHits  atomic.Int32
	truncated bool
}

func newFakeGitHub(t *testing.T, releases map[string][]string, latest string) *fakeGitHub {
	t.Helper()
	f := &fakeGitHub{releases: releases, latest: latest}
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/Tsuky44/player/releases/", func(w http.ResponseWriter, r *http.Request) {
		f.apiHits.Add(1)
		tag := filepath.Base(r.URL.Path)
		if tag == "latest" {
			tag = f.latest
		}
		names, ok := f.releases[tag]
		if !ok {
			http.NotFound(w, r)
			return
		}
		type asset struct {
			Name string `json:"name"`
			Size int64  `json:"size"`
			URL  string `json:"browser_download_url"`
		}
		body := struct {
			Tag    string  `json:"tag_name"`
			Assets []asset `json:"assets"`
		}{Tag: tag}
		for _, n := range names {
			body.Assets = append(body.Assets, asset{n, int64(len(payload(n))), f.server.URL + "/files/" + tag + "/" + n})
		}
		_ = json.NewEncoder(w).Encode(body)
	})
	mux.HandleFunc("/files/", func(w http.ResponseWriter, r *http.Request) {
		f.fileHits.Add(1)
		name := filepath.Base(r.URL.Path)
		content := payload(name)
		if f.truncated {
			content = content[:len(content)/2]
		}
		_, _ = w.Write([]byte(content))
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func payload(name string) string { return "contenu-de-" + name }

func newSource(t *testing.T, f *fakeGitHub, version, cacheDir string) *Source {
	t.Helper()
	return New(Config{Version: version, APIBase: f.server.URL, CacheDir: cacheDir})
}

func names(assets []Asset) []string {
	out := make([]string, 0, len(assets))
	for _, a := range assets {
		out = append(out, a.Name)
	}
	return out
}

func TestServerProposesTheInstallersOfItsOwnVersion(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{
		"v1.1.0": {"Onyx-1.1.0-android.apk"},
		"v1.2.0": {"Onyx-1.2.0-android.apk", "Onyx-1.2.0-windows.exe"},
		"v1.3.0": {"Onyx-1.3.0-android.apk"},
	}, "v1.3.0")

	// Un serveur en 1.2.0 n'est ni en retard sur 1.3.0 ni en avance sur 1.1.0 :
	// il propose les installeurs de la 1.2.0.
	got := names(newSource(t, f, "1.2.0", t.TempDir()).Assets(context.Background()))
	if len(got) != 2 || got[0] != "Onyx-1.2.0-android.apk" {
		t.Fatalf("assets of a 1.2.0 server = %v", got)
	}
}

func TestDevelopmentBuildFallsBackToTheLatestRelease(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{
		"v1.3.0": {"Onyx-1.3.0-android.apk"},
	}, "v1.3.0")

	for _, version := range []string{"dev", "main-8bd07f0d"} {
		got := names(newSource(t, f, version, t.TempDir()).Assets(context.Background()))
		if len(got) != 1 || got[0] != "Onyx-1.3.0-android.apk" {
			t.Errorf("assets of a %q build = %v, want the latest release", version, got)
		}
	}
}

func TestUnknownReleaseOffersNothing(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{"v1.3.0": {"Onyx-1.3.0-android.apk"}}, "v1.3.0")
	if got := newSource(t, f, "9.9.9", t.TempDir()).Assets(context.Background()); len(got) != 0 {
		t.Fatalf("a version with no Release must not borrow another one: %v", got)
	}
}

func TestInstallerIsDownloadedOnceThenServedFromTheCache(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{"v1.2.0": {"Onyx-1.2.0-android.apk"}}, "v1.2.0")
	src := newSource(t, f, "1.2.0", t.TempDir())
	ctx := context.Background()

	asset, ok := src.Find(ctx, "Onyx-1.2.0-android.apk")
	if !ok {
		t.Fatal("asset not listed")
	}
	if _, cached := src.Cached(asset); cached {
		t.Fatal("cached before any download")
	}
	for i := 0; i < 2; i++ {
		path, err := src.Ensure(ctx, asset)
		if err != nil {
			t.Fatalf("Ensure: %v", err)
		}
		raw, _ := os.ReadFile(path)
		if string(raw) != payload("Onyx-1.2.0-android.apk") {
			t.Fatalf("content = %q", raw)
		}
	}
	if hits := f.fileHits.Load(); hits != 1 {
		t.Errorf("the file was fetched %d times, want 1", hits)
	}
}

func TestTruncatedDownloadNeverPassesForTheFile(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{"v1.2.0": {"Onyx-1.2.0-android.apk"}}, "v1.2.0")
	f.truncated = true
	src := newSource(t, f, "1.2.0", t.TempDir())
	ctx := context.Background()

	asset, _ := src.Find(ctx, "Onyx-1.2.0-android.apk")
	if _, err := src.Ensure(ctx, asset); err == nil {
		t.Fatal("a download shorter than the announced size was accepted")
	}
	if _, cached := src.Cached(asset); cached {
		t.Error("the half file is served as if it were whole")
	}
}

func TestNameOutsideTheReleaseIsNotFetched(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{"v1.2.0": {"Onyx-1.2.0-android.apk"}}, "v1.2.0")
	src := newSource(t, f, "1.2.0", t.TempDir())
	if _, ok := src.Find(context.Background(), "../../etc/passwd"); ok {
		t.Fatal("a name that is not in the Release was accepted")
	}
}

func TestListingSurvivesLosingTheNetwork(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{"v1.2.0": {"Onyx-1.2.0-android.apk"}}, "v1.2.0")
	cache := t.TempDir()
	if got := newSource(t, f, "1.2.0", cache).Assets(context.Background()); len(got) != 1 {
		t.Fatalf("first listing = %v", got)
	}

	f.server.Close()
	// Un redémarrage hors ligne : une Source neuve, le même cache.
	got := names(newSource(t, f, "1.2.0", cache).Assets(context.Background()))
	if len(got) != 1 || got[0] != "Onyx-1.2.0-android.apk" {
		t.Fatalf("offline listing = %v, want the one kept on disk", got)
	}
}

func TestUpdatingTheServerDropsThePreviousInstallers(t *testing.T) {
	f := newFakeGitHub(t, map[string][]string{
		"v1.1.0": {"Onyx-1.1.0-android.apk"},
		"v1.2.0": {"Onyx-1.2.0-android.apk"},
	}, "v1.2.0")
	cache := t.TempDir()
	ctx := context.Background()

	old := newSource(t, f, "1.1.0", cache)
	oldAsset, _ := old.Find(ctx, "Onyx-1.1.0-android.apk")
	if _, err := old.Ensure(ctx, oldAsset); err != nil {
		t.Fatal(err)
	}

	newSource(t, f, "1.2.0", cache).Assets(ctx)
	if _, err := os.Stat(filepath.Join(cache, "v1.1.0")); !os.IsNotExist(err) {
		t.Errorf("the 1.1.0 installers are still on disk: %v", err)
	}
}

func TestDisabledSourceOffersNothing(t *testing.T) {
	var src *Source
	if got := src.Assets(context.Background()); len(got) != 0 {
		t.Fatalf("nil source listed %v", got)
	}
	if _, err := src.Ensure(context.Background(), Asset{Name: "x.apk"}); err == nil {
		t.Fatal("nil source downloaded something")
	}
}
