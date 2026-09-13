package streaming

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"project-player/server/playbackauth"
)

func TestPreviewIntervalStaysWithinBounds(t *testing.T) {
	cases := []struct {
		duration float64
		want     int
	}{
		{0, previewMinInterval},
		{60, previewMinInterval},
		{22 * 60, previewMinInterval},
		{2 * 3600, 12},
		{12 * 3600, previewMaxInterval},
	}
	for _, c := range cases {
		if got := previewInterval(c.duration); got != c.want {
			t.Errorf("previewInterval(%v) = %d, want %d", c.duration, got, c.want)
		}
	}
	if got := previewCount(7201, 12); got != 601 {
		t.Errorf("previewCount rounds the tail up: got %d, want 601", got)
	}
}

func TestPreviewHeightKeepsAspectOnEvenPixels(t *testing.T) {
	if got := previewHeight(3840, 1606); got != 202 {
		t.Errorf("scope height = %d, want 202", got)
	}
	if got := previewHeight(1920, 1080); got != 270 {
		t.Errorf("16:9 height = %d, want 270", got)
	}
	if got := previewHeight(0, 0); got != 270 {
		t.Errorf("unknown dimensions height = %d, want 270", got)
	}
}

func TestPreviewOrderIsCoarseToFineAndComplete(t *testing.T) {
	order := previewOrder(9)
	want := []int{0, 8, 4, 2, 6, 1, 3, 5, 7}
	if len(order) != len(want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
	seen := map[int]bool{}
	for _, i := range previewOrder(601) {
		if seen[i] {
			t.Fatalf("index %d scheduled twice", i)
		}
		seen[i] = true
	}
	if len(seen) != 601 {
		t.Fatalf("scheduled %d of 601 stills", len(seen))
	}
}

func TestPreviewArgsSeekOnKeyframesAndToneMapAfterScaling(t *testing.T) {
	setFilterSetForTest("zscale", "tonemap")
	args := strings.Join(previewArgs("/m/film.mkv", 120, true, true, 1), " ")
	for _, part := range []string{"-skip_frame nokey -ss 120 -noaccurate_seek -i /m/film.mkv", "-map 0:V:0", "-frames:v 1"} {
		if !strings.Contains(args, part) {
			t.Errorf("args %q missing %q", args, part)
		}
	}
	if scale, tm := strings.Index(args, "scale=480"), strings.Index(args, "tonemap="); scale < 0 || tm < scale {
		t.Errorf("tone mapping must follow the scale: %q", args)
	}
	if strings.Contains(strings.Join(previewArgs("/m/film.mkv", 0, false, false, 1), " "), "skip_frame") {
		t.Error("the fallback extraction must decode every frame")
	}
}

func testPreviewSet(t *testing.T, g *previewGenerator, count int) *previewSet {
	t.Helper()
	return &previewSet{
		mediaID:  7,
		filePath: "/m/film.mkv",
		dir:      filepath.Join(g.root, "7-test"),
		manifest: PreviewManifest{Interval: 10, Count: count, Width: previewWidth, Height: 270},
	}
}

func TestPreviewEnsureSharesOneExtractionPerStill(t *testing.T) {
	g := newPreviewGenerator(t.TempDir(), nil)
	var runs atomic.Int32
	release := make(chan struct{})
	g.run = func(ctx context.Context, args []string, background bool) ([]byte, error) {
		runs.Add(1)
		<-release
		return []byte("jpeg"), nil
	}
	set := testPreviewSet(t, g, 10)

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(background bool) {
			defer wg.Done()
			if _, err := g.ensure(context.Background(), set, 3, background); err != nil {
				t.Error(err)
			}
		}(i%2 == 0)
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()

	if got := runs.Load(); got != 1 {
		t.Fatalf("ffmpeg ran %d times for one still", got)
	}
	data, err := os.ReadFile(set.path(3))
	if err != nil || string(data) != "jpeg" {
		t.Fatalf("still on disk = %q, %v", data, err)
	}
	// Already on disk: no extraction at all.
	if _, err := g.ensure(context.Background(), set, 3, false); err != nil || runs.Load() != 1 {
		t.Fatalf("cached still re-extracted (runs=%d, err=%v)", runs.Load(), err)
	}
}

func TestPreviewEnsureFallsBackToFullDecode(t *testing.T) {
	g := newPreviewGenerator(t.TempDir(), nil)
	g.run = func(ctx context.Context, args []string, background bool) ([]byte, error) {
		if strings.Contains(strings.Join(args, " "), "skip_frame") {
			return nil, nil
		}
		return []byte("jpeg"), nil
	}
	set := testPreviewSet(t, g, 2)
	if _, err := g.ensure(context.Background(), set, 1, false); err != nil {
		t.Fatal(err)
	}
}

func TestPreviewWarmStopsWhenTheTicketIsRevoked(t *testing.T) {
	tickets := playbackauth.NewStore()
	token, _, err := tickets.Issue(1, 7)
	if err != nil {
		t.Fatal(err)
	}
	g := newPreviewGenerator(t.TempDir(), tickets)
	var runs atomic.Int32
	g.run = func(ctx context.Context, args []string, background bool) ([]byte, error) {
		if !background {
			t.Error("the warm pass must run in the background")
		}
		if runs.Add(1) == 3 {
			tickets.Revoke(token, 1)
		}
		return []byte("jpeg"), nil
	}
	set := testPreviewSet(t, g, 50)
	g.warm(set, playbackauth.Digest(token))
	// A second warm for the same set while running is a no-op.
	g.warm(set, playbackauth.Digest(token))

	g.mu.Lock()
	job := g.jobs[set.dir]
	g.mu.Unlock()
	select {
	case <-job.done:
	case <-time.After(5 * time.Second):
		t.Fatal("warm pass did not stop")
	}
	if got := runs.Load(); got != 3 {
		t.Fatalf("warm pass made %d stills after revocation, want 3", got)
	}
}

func TestPreviewWarmCompletesAndPrunesOtherSets(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PREVIEW_CACHE_MB", "0")
	g := newPreviewGenerator(root, nil)
	g.run = func(ctx context.Context, args []string, background bool) ([]byte, error) {
		return []byte("jpeg"), nil
	}
	set := testPreviewSet(t, g, 20)
	g.warm(set, [32]byte{})
	g.mu.Lock()
	job := g.jobs[set.dir]
	g.mu.Unlock()
	<-job.done
	for i := 0; i < 20; i++ {
		if !fileExists(set.path(i)) {
			t.Fatalf("still %d missing after a full pass", i)
		}
	}

	// Over budget: the stale set goes, the one being watched stays.
	t.Setenv("PREVIEW_CACHE_MB", "1")
	stale := filepath.Join(root, "3-stale")
	os.MkdirAll(stale, 0o755)
	os.WriteFile(filepath.Join(stale, "0.jpg"), bytes.Repeat([]byte{1}, 2<<20), 0o644)
	old := time.Now().Add(-time.Hour)
	os.Chtimes(stale, old, old)
	g.prune(set.dir)
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("least recently used set survived pruning")
	}
	if !fileExists(set.path(0)) {
		t.Fatal("pruning removed the set being watched")
	}
}

// Real FFmpeg on a generated clip: the stills come out as JPEGs of the
// advertised width, fast enough to answer a hover.
func TestPreviewExtractionWithFFmpeg(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	dir := t.TempDir()
	media := filepath.Join(dir, "clip.mkv")
	gen := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
		"-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-t", "30",
		"-c:v", "libx264", "-preset", "ultrafast", "-g", "48", media)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("cannot generate test clip: %v %s", err, out)
	}
	info, err := os.Stat(media)
	if err != nil {
		t.Fatal(err)
	}
	probe := &ProbeResult{Duration: 30, Video: &VideoStreamInfo{Width: 1280, Height: 720}}
	g := newPreviewGenerator(filepath.Join(dir, "previews"), nil)
	set := newPreviewSet(g.root, 1, media, info, probe, 30)
	if set.manifest.Count != 8 || set.manifest.Height != 270 {
		t.Fatalf("manifest = %+v", set.manifest)
	}
	for _, index := range []int{0, 5, set.manifest.Count - 1} {
		start := time.Now()
		path, err := g.ensure(context.Background(), set, index, false)
		if err != nil {
			t.Fatalf("still %d: %v", index, err)
		}
		t.Logf("still %d in %s", index, time.Since(start))
		data, err := os.ReadFile(path)
		if err != nil || len(data) < 1000 || !bytes.HasPrefix(data, []byte{0xFF, 0xD8}) {
			t.Fatalf("still %d is not a JPEG (%d bytes, %v)", index, len(data), err)
		}
	}
}
