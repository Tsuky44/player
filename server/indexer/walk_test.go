package indexer

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

func collectWalk(t *testing.T, root string) []string {
	t.Helper()
	beginScanReport(root, "")
	defer finishScanReport()

	var found []string
	walkVideoFiles(root, sectionMovies, func(path string, info os.FileInfo) {
		rel, err := filepath.Rel(root, path)
		if err != nil {
			t.Fatal(err)
		}
		found = append(found, filepath.ToSlash(rel))
	})
	sort.Strings(found)
	return found
}

func TestWalkVideoFiles_FindsAllSupportedContainers(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Inception (2010)"), "Inception.mkv")
	writeVideo(t, filepath.Join(root, "Heat (1995)"), "Heat.m4v")
	writeVideo(t, filepath.Join(root, "Casino (1995)"), "Casino.ts")
	writeVideo(t, filepath.Join(root, "Fargo (1996)"), "Fargo.m2ts")
	writeVideo(t, filepath.Join(root, "Alien (1979)"), "Alien.mpg")
	writeVideo(t, root, "notes.txt")

	got := collectWalk(t, root)
	if len(got) != 5 {
		t.Fatalf("found %d files (%v), want the 5 videos — a missing extension silently drops films", len(got), got)
	}
}

func TestWalkVideoFiles_ContinuesPastUnreadableEntries(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Before"), "Before.mkv")
	if err := os.Symlink(filepath.Join(root, "nowhere.mkv"), filepath.Join(root, "broken.mkv")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := os.Symlink(filepath.Join(root, "missing-dir"), filepath.Join(root, "broken-dir")); err != nil {
		t.Fatal(err)
	}
	writeVideo(t, filepath.Join(root, "Zulu"), "Zulu.mkv")

	got := collectWalk(t, root)
	if len(got) != 2 {
		t.Fatalf("got %v, want both real films — a broken link must not stop the scan", got)
	}
}

func TestWalkVideoFiles_FollowsDirectorySymlinksWithoutLooping(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()
	writeVideo(t, filepath.Join(external, "Dune (2021)"), "Dune.mkv")
	if err := os.Symlink(external, filepath.Join(root, "linked")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	// Self-referencing link: the walk must not spin forever.
	if err := os.Symlink(root, filepath.Join(root, "loop")); err != nil {
		t.Fatal(err)
	}

	got := collectWalk(t, root)
	if len(got) != 1 {
		t.Fatalf("got %v, want the film behind the directory symlink", got)
	}
}

func TestWalkVideoFiles_SkipsJunkExtrasAndSamples(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)", "Extras"), "Making of.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival-trailer.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.1080p.sample.mkv")
	writeVideo(t, filepath.Join(root, "@eaDir"), "thumb.mkv")
	writeVideo(t, filepath.Join(root, "Titanic (1997)"), "Titanic.cd1.avi")
	writeVideo(t, filepath.Join(root, "Titanic (1997)"), "Titanic.cd2.avi")

	got := collectWalk(t, root)
	want := []string{"Arrival (2016)/Arrival.mkv", "Titanic (1997)/Titanic.cd1.avi"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestWalkVideoFiles_SkipsDiscStructures(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Old Movie", "VIDEO_TS"), "VTS_01_1.VOB")
	writeVideo(t, filepath.Join(root, "Old Movie", "VIDEO_TS"), "VTS_01_2.VOB")
	writeVideo(t, filepath.Join(root, "New Movie"), "New.mkv")

	got := collectWalk(t, root)
	if len(got) != 1 || got[0] != "New Movie/New.mkv" {
		t.Fatalf("got %v — DVD folders must not create one film per VOB", got)
	}
}

func TestIsExtraFileName(t *testing.T) {
	extras := []string{"sample.mkv", "Arrival-trailer.mkv", "Movie.1080p.sample.mkv", "Film-featurette.mp4", "trailer.mp4"}
	for _, name := range extras {
		if !IsExtraFileName(name) {
			t.Errorf("%q should be treated as an extra", name)
		}
	}
	keep := []string{"Trailer Park Boys (2019).mkv", "Sample Size (2021).mkv", "Inception.2010.mkv", "The Interview (2014).mkv"}
	for _, name := range keep {
		if IsExtraFileName(name) {
			t.Errorf("%q is a real film, it must be indexed", name)
		}
	}
}

func TestMultipartKey(t *testing.T) {
	tests := []struct {
		in       string
		wantKey  string
		wantPart int
		wantOK   bool
	}{
		{"Titanic.cd1", "Titanic", 1, true},
		{"Titanic.cd2", "Titanic", 2, true},
		{"Film (part 3)", "Film", 3, true},
		{"Film - disc 2", "Film", 2, true},
		{"Inception.2010.1080p", "Inception.2010.1080p", 0, false},
		{"Ocean's Eleven", "Ocean's Eleven", 0, false},
	}
	for _, tt := range tests {
		key, part, ok := MultipartKey(tt.in)
		if ok != tt.wantOK || part != tt.wantPart || key != tt.wantKey {
			t.Errorf("MultipartKey(%q) = (%q, %d, %v), want (%q, %d, %v)",
				tt.in, key, part, ok, tt.wantKey, tt.wantPart, tt.wantOK)
		}
	}
}

func TestScanReportRecordsSkipReasons(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.mkv")
	writeVideo(t, filepath.Join(root, "Arrival (2016)"), "Arrival.1080p.sample.mkv")

	beginScanReport(root, "")
	walkVideoFiles(root, sectionMovies, func(path string, info os.FileInfo) {})
	finishScanReport()

	report := LastScanReport()
	if report.Movies.VideoFiles != 2 {
		t.Fatalf("video files = %d, want 2", report.Movies.VideoFiles)
	}
	if report.Movies.Skipped != 1 || len(report.Skipped) != 1 {
		t.Fatalf("skipped = %d (%v), want 1", report.Movies.Skipped, report.Skipped)
	}
	if report.Running {
		t.Fatal("report should be finished")
	}
}
