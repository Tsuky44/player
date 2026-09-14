package indexer

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"

	"project-player/server/database"
)

// testMonitor builds a monitor over a series library without starting any of
// its loops: tests drive runTarget, takeDue and pollOnce directly. Files are
// ready on first look unless a test says otherwise.
func testMonitor(t *testing.T, seriesDir string) *libraryMonitor {
	t.Helper()
	m := newLibraryMonitor(MonitorOptions{
		Roots: func() (string, string) { return "", seriesDir },
	})
	m.settledAge = 0
	return m
}

// mapSeries runs a library scan of the series root that hands the folder map
// to the monitor, as the startup scan does.
func mapSeries(t *testing.T, m *libraryMonitor, root string) {
	t.Helper()
	beginScanReport("", root)
	defer finishScanReport()
	scope := fullScope(root)
	scope.opts.onDir = m.recordDir
	scanSeriesScope(scope)
}

func countOfType(t *testing.T, mediaType string) int {
	t.Helper()
	var n int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type = ?`, mediaType).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// ageTree sets every folder and file under root an hour back, so the monitor's
// "modified in the last seconds" guards see a settled library.
func ageTree(t *testing.T, root string) {
	t.Helper()
	past := time.Now().Add(-time.Hour)
	err := filepath.Walk(root, func(path string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chtimes(path, past, past)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func buildSeriesLibrary(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Breaking Bad", "Season 1"), "Breaking.Bad.S01E01.mkv")
	writeVideo(t, filepath.Join(root, "Breaking Bad", "Season 1"), "Breaking.Bad.S01E02.mkv")
	writeVideo(t, filepath.Join(root, "Kaamelott", "Saison 1"), "Kaamelott.S01E01.mkv")
	return root
}

func TestMonitor_ShallowScanIndexesTheNewEpisode(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	mapSeries(t, m, root)

	season := filepath.Join(root, "Breaking Bad", "Season 1")
	writeVideo(t, season, "Breaking.Bad.S01E03.mkv")

	var result batchResult
	m.runTarget(dueTarget{path: season}, &result)

	if len(result.added) != 1 {
		t.Fatalf("added %d rows, want the one new episode", len(result.added))
	}
	if got := countOfType(t, "episode"); got != 4 {
		t.Fatalf("episodes = %d, want 4", got)
	}
	if got := countOfType(t, "show"); got != 2 {
		t.Fatalf("shows = %d, want 2 — the episode must join its existing show", got)
	}
}

func TestMonitor_FileStillBeingWrittenWaitsAndIsRequeued(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	mapSeries(t, m, root)
	m.settledAge = time.Hour
	m.settleTime = time.Hour

	season := filepath.Join(root, "Breaking Bad", "Season 1")
	writeVideo(t, season, "Breaking.Bad.S01E03.mkv")

	var result batchResult
	m.runTarget(dueTarget{path: season}, &result)

	if len(result.added) != 0 {
		t.Fatal("a file seen once, and just written, must not be indexed yet")
	}
	if _, queued := m.targets[season]; !queued {
		t.Fatal("the folder must be queued again, or the file is never indexed")
	}
}

func TestMonitor_FileReadyNeedsTwoMatchingLooks(t *testing.T) {
	m := testMonitor(t, t.TempDir())
	m.settledAge = time.Hour
	m.settleTime = 30 * time.Millisecond

	path := writeVideo(t, t.TempDir(), "Show.S01E01.mkv")
	look := func() bool {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		return m.fileReady(path, info)
	}

	if look() {
		t.Fatal("first look: not ready")
	}
	time.Sleep(40 * time.Millisecond)
	if err := os.WriteFile(path, []byte("grown"), 0o644); err != nil {
		t.Fatal(err)
	}
	if look() {
		t.Fatal("the file grew since the first look: not ready")
	}
	if look() {
		t.Fatal("unchanged, but not settleTime after the look that saw its size: not ready")
	}
	time.Sleep(40 * time.Millisecond)
	if !look() {
		t.Fatal("unchanged across settleTime: ready")
	}
}

func TestMonitor_RemovedShowFolderIsCleanedUp(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	mapSeries(t, m, root)

	show := filepath.Join(root, "Breaking Bad")
	if err := os.RemoveAll(show); err != nil {
		t.Fatal(err)
	}

	var result batchResult
	m.runTarget(dueTarget{path: show}, &result)

	if result.removed != 2 {
		t.Fatalf("removed %d rows, want the 2 episodes", result.removed)
	}
	if got := countOfType(t, "show"); got != 1 {
		t.Fatalf("shows = %d, want 1 — the empty show must go with its episodes", got)
	}
	if m.isKnownDir(filepath.Join(show, "Season 1")) {
		t.Fatal("the removed folders must leave the map")
	}
}

func TestMonitor_EmptiedLibraryRootDeletesNothing(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	mapSeries(t, m, root)

	// What an unmounted share looks like from inside the container: the mount
	// point is still there, with nothing in it.
	entries, _ := os.ReadDir(root)
	for _, entry := range entries {
		if err := os.RemoveAll(filepath.Join(root, entry.Name())); err != nil {
			t.Fatal(err)
		}
	}

	var result batchResult
	m.runTarget(dueTarget{path: filepath.Join(root, "Breaking Bad")}, &result)

	if result.removed != 0 || countOfType(t, "episode") != 3 {
		t.Fatal("an empty library root means offline storage: no row may be deleted")
	}
}

func TestMonitor_NewShowFolderFoundByShallowScanOfTheRoot(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	mapSeries(t, m, root)

	writeVideo(t, filepath.Join(root, "The Wire", "Season 1"), "The.Wire.S01E01.mkv")

	var result batchResult
	m.runTarget(dueTarget{path: root}, &result)
	if countOfType(t, "episode") != 3 {
		t.Fatal("a shallow scan of the root must not walk the whole library")
	}

	batch, _ := m.takeDue(time.Now())
	if len(batch) != 1 || batch[0].path != filepath.Join(root, "The Wire") || !batch[0].deep {
		t.Fatalf("queued %v, want a deep scan of the new show folder", batch)
	}
	m.runBatch(batch)
	if got := countOfType(t, "episode"); got != 4 {
		t.Fatalf("episodes = %d, want 4", got)
	}
}

func TestMonitor_TakeDueDropsWhatADeepAncestorCovers(t *testing.T) {
	m := testMonitor(t, "/library")
	m.enqueue("/library/Show", true, 0)
	m.enqueue("/library/Show/Season 1", false, 0)
	m.enqueue("/library/Showcase", false, 0)
	m.enqueue("/library/Later", false, time.Hour)

	batch, next := m.takeDue(time.Now())
	if len(batch) != 2 || batch[0].path != "/library/Show" || batch[1].path != "/library/Showcase" {
		t.Fatalf("batch = %v, want the show and its look-alike sibling, not the season", batch)
	}
	if next <= 0 || next > time.Hour {
		t.Fatalf("next wake in %v, want the pending target's delay", next)
	}
}

func TestMonitor_PollFindsTheFolderThatChanged(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	ageTree(t, root)
	m := testMonitor(t, root)
	mapSeries(t, m, root)

	m.pollOnce()
	if batch, _ := m.takeDue(time.Now()); len(batch) != 0 {
		t.Fatalf("nothing changed, but the poll queued %v", batch)
	}

	season := filepath.Join(root, "Kaamelott", "Saison 1")
	writeVideo(t, season, "Kaamelott.S01E02.mkv")

	m.pollOnce()
	batch, _ := m.takeDue(time.Now())
	if len(batch) != 1 || batch[0].path != season || batch[0].deep {
		t.Fatalf("poll queued %v, want a shallow scan of %s", batch, season)
	}
}

func TestMonitor_NotificationIndexesANewEpisode(t *testing.T) {
	setupMovieDB(t)
	root := buildSeriesLibrary(t)
	m := testMonitor(t, root)
	m.eventQuiet = 20 * time.Millisecond
	m.settleTime = 50 * time.Millisecond
	m.settledAge = time.Hour

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Skipf("filesystem notifications unavailable: %v", err)
	}
	m.watcher = watcher
	t.Cleanup(func() {
		close(m.stop)
		watcher.Close()
	})
	mapSeries(t, m, root)
	go m.watchLoop()
	go m.runLoop()

	// A new season folder, then its episode inside it: the folder's own watch
	// does not exist yet when the file lands, so the deep scan must find it.
	writeVideo(t, filepath.Join(root, "Kaamelott", "Saison 2"), "Kaamelott.S02E01.mkv")

	deadline := time.Now().Add(10 * time.Second)
	for countOfType(t, "episode") != 4 {
		if time.Now().After(deadline) {
			t.Fatal("the new episode was not indexed from the notification")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !m.isKnownDir(filepath.Join(root, "Kaamelott", "Saison 2")) {
		t.Fatal("the new folder must join the map, so its own changes are watched")
	}
}
