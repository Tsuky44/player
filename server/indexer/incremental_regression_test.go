package indexer

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/httpx"
)

type metadataTransport func(*http.Request) (*http.Response, error)

func (f metadataTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestBackfillDoesNotFetchCompleteLibrary(t *testing.T) {
	setupMovieDB(t)
	t.Setenv("TMDB_API_KEY", "test-key")
	calls := 0
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old })
	for _, q := range []string{
		`INSERT INTO medias (id,type,title,tmdb_id,poster_url,overview,release_date) VALUES (1,'movie','Alien',348,'poster','overview','1979-05-25')`,
		`INSERT INTO medias (id,type,title,tmdb_id,poster_url,overview,release_date) VALUES (2,'show','Show',123,'poster','overview','2020-01-01')`,
		`INSERT INTO medias (id,type,title,parent_id,season_number) VALUES (3,'season','Saison 1',2,1)`,
		`INSERT INTO medias (id,type,title,parent_id,season_number,episode_number,tmdb_id,poster_url,overview,release_date) VALUES (4,'episode','Pilot',3,1,1,456,'poster','overview','2020-01-01')`,
	} {
		if _, err := database.DB.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	backfillMissingMetadata()
	if calls != 0 {
		t.Fatalf("unchanged, complete library made %d TMDB requests; want 0", calls)
	}
}

func TestCollectMovieLocalIdentity_DoesNotInheritSharedFolderMetadata(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Collection [tmdbid-999]")
	video := writeVideo(t, dir, "Alien.1979.mkv")
	writeVideo(t, dir, "Arrival.2016.mkv")
	if err := os.WriteFile(filepath.Join(dir, "movie.nfo"), []byte(`<movie><title>Wrong movie</title><tmdbid>999</tmdbid></movie>`), 0600); err != nil {
		t.Fatal(err)
	}
	hints := CollectMovieLocalIdentity(video, root)
	if hints.TMDBID != 0 || hints.Title != "Alien" || hints.Year != 1979 {
		t.Fatalf("shared metadata leaked: %+v", hints)
	}
}

func TestScanMovies_RefreshesChangedFileWithoutReplacingIdentity(t *testing.T) {
	setupMovieDB(t)
	root := t.TempDir()
	path := writeVideo(t, root, "Alien.1979.mkv")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	id := insertMovie(t, "My corrected title", path, 348)
	if _, err := database.DB.Exec(`UPDATE medias SET file_size=1,file_mod_time=?,tracks_json='cached',duration=120,gop_seconds=2 WHERE id=?`, info.ModTime().Unix(), id); err != nil {
		t.Fatal(err)
	}
	scanMovies(root)
	var tracks string
	if err := database.DB.QueryRow(`SELECT tracks_json FROM medias WHERE id=?`, id).Scan(&tracks); err != nil || tracks != "cached" {
		t.Fatalf("unchanged cache lost: %q (%v)", tracks, err)
	}
	if err := os.WriteFile(path, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	scanMovies(root)
	var size int64
	var title string
	var tmdb int
	if err := database.DB.QueryRow(`SELECT file_size,title,tmdb_id,COALESCE(tracks_json,'') FROM medias WHERE id=?`, id).Scan(&size, &title, &tmdb, &tracks); err != nil {
		t.Fatal(err)
	}
	if size != 11 || tracks != "" {
		t.Fatalf("changed file not refreshed: size=%d tracks=%q", size, tracks)
	}
	if title != "My corrected title" || tmdb != 348 {
		t.Fatal("manual identity overwritten")
	}
}

func TestIdentifyShow_UsesTVDBIDBeforeTitleSearch(t *testing.T) {
	t.Setenv("TMDB_API_KEY", "test-key")
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		body := `{"name":"Correct show"}`
		if strings.HasPrefix(r.URL.Path, "/3/search/") {
			t.Error("explicit TVDB identity ignored in favor of title search")
		}
		if strings.HasPrefix(r.URL.Path, "/3/find/") {
			if r.URL.Query().Get("external_source") != "tvdb_id" {
				t.Error("wrong external source")
			}
			body = `{"tv_results":[{"id":1396}]}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old })
	match := IdentifyShow(t.TempDir(), "Incorrect name [tvdbid-81189]")
	if !match.Matched || match.TMDBID != 1396 {
		t.Fatalf("TVDB match failed: %+v", match)
	}
}

func TestIdentifyMovie_FallsBackToFilenameWhenFolderSearchFails(t *testing.T) {
	t.Setenv("TMDB_API_KEY", "test-key")
	ResetSearchCache()
	ResetDirScanCache()
	root := t.TempDir()
	path := writeVideo(t, filepath.Join(root, "Unknown download folder"), "Alien.1979.mkv")
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		body := `{}`
		if strings.HasPrefix(r.URL.Path, "/3/search/") && r.URL.Query().Get("query") == "Alien" {
			body = `{"results":[{"id":348,"title":"Alien","release_date":"1979-05-25"}]}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old; ResetSearchCache() })
	match := IdentifyMovie(path, root)
	if !match.Matched || match.TMDBID != 348 {
		t.Fatalf("filename fallback failed: %+v", match)
	}
}

func TestCollectMovieLocalIdentity_UsesPerFileNFOInSharedFolder(t *testing.T) {
	ResetDirScanCache()
	root := t.TempDir()
	video := writeVideo(t, root, "Alien.1979.mkv")
	writeVideo(t, root, "Arrival.2016.mkv")
	if err := os.WriteFile(filepath.Join(root, "Alien.1979.nfo"), []byte(`<movie><title>Alien</title><tmdbid>348</tmdbid></movie>`), 0600); err != nil {
		t.Fatal(err)
	}
	if got := CollectMovieLocalIdentity(video, root); got.TMDBID != 348 {
		t.Fatalf("per-file NFO ignored: %+v", got)
	}
}

func TestScanSeries_IdentifiesShowOnceForSeveralEpisodes(t *testing.T) {
	setupMovieDB(t)
	t.Setenv("TMDB_API_KEY", "test-key")
	ResetSearchCache()
	ResetDirScanCache()
	root := t.TempDir()
	dir := filepath.Join(root, "Breaking Bad [tmdbid-1396]", "Season 1")
	writeVideo(t, dir, "BB.S01E01.mkv")
	writeVideo(t, dir, "BB.S01E02.mkv")
	calls := 0
	old := httpx.Standard
	httpx.Standard = &http.Client{Transport: metadataTransport(func(r *http.Request) (*http.Response, error) {
		body := `{}`
		if r.URL.Path == "/3/tv/1396" {
			calls++
			body = `{"id":1396,"name":"Breaking Bad","overview":"Overview","poster_path":"/poster","first_air_date":"2008-01-20"}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { httpx.Standard = old; ResetSearchCache() })
	scanSeries(root)
	if calls != 1 {
		t.Fatalf("identified same show %d times; want 1", calls)
	}
}
