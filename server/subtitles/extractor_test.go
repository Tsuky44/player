package subtitles

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/streaming"
)

func sub(lang string, typed int, image bool) streaming.SubtitleStreamInfo {
	return streaming.SubtitleStreamInfo{
		TypedIndex: typed,
		Language:   lang,
		Image:      image,
		Codec:      "subrip",
	}
}

func TestPlanTextSubtitles_KeysAndFiltering(t *testing.T) {
	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("fre", 0, false), // -> fr
		sub("eng", 1, false), // -> en
		sub("fra", 2, false), // second French -> fr2
		sub("spa", 3, true),  // image (PGS) -> skipped entirely
		sub("eng", 4, false), // second English -> en2
	}}

	planned := planTextSubtitles(42, probe, "/subs")

	if len(planned) != 4 {
		t.Fatalf("expected 4 text tracks (image one dropped), got %d", len(planned))
	}

	wantKeys := []string{"fr", "en", "fr2", "en2"}
	for i, want := range wantKeys {
		if planned[i].key != want {
			t.Errorf("track %d: key = %q, want %q", i, planned[i].key, want)
		}
	}

	// The typed index must keep pointing at the ORIGINAL stream, not the
	// position in the filtered list — otherwise ffmpeg maps the wrong track.
	wantTyped := []int{0, 1, 2, 4}
	for i, want := range wantTyped {
		if planned[i].typedIndex != want {
			t.Errorf("track %d: typedIndex = %d, want %d", i, planned[i].typedIndex, want)
		}
	}

	if got := filepath.Base(planned[2].path); got != "m42.fr2.vtt" {
		t.Errorf("path basename = %q, want m42.fr2.vtt", got)
	}
}

func TestPlanTextSubtitles_MatchesCatalogKeys(t *testing.T) {
	// planTextSubtitles decides the on-disk filename; Catalog decides the key the
	// client asks for. If the two ever disagree, every subtitle 404s — so pin the
	// shared derivation here.
	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("", 0, false),    // untagged -> und
		sub("ger", 1, false), // -> de
		sub("", 2, false),    // second untagged -> und2
	}}

	planned := planTextSubtitles(7, probe, "/subs")

	seen := map[string]int{}
	for i, s := range probe.Subtitles {
		code := normalizeLang(s.Language)
		key := code
		if seen[code] > 0 {
			key = code + string(rune('0'+seen[code]+1))
		}
		seen[code]++
		if planned[i].key != key {
			t.Errorf("track %d: planned key %q != catalog key %q", i, planned[i].key, key)
		}
	}
}

func TestPlanTextSubtitles_AllImageYieldsNothing(t *testing.T) {
	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("eng", 0, true),
		sub("fre", 1, true),
	}}
	if planned := planTextSubtitles(1, probe, "/subs"); len(planned) != 0 {
		t.Fatalf("bitmap-only file should plan no extraction, got %d", len(planned))
	}
}

// --- end-to-end, requires ffmpeg ---

func writeSRT(t *testing.T, path, text string, lines int) {
	t.Helper()
	var b strings.Builder
	for i := 1; i <= lines; i++ {
		start := i * 2
		b.WriteString(itoa(i) + "\n")
		b.WriteString(ts(start) + " --> " + ts(start+1) + "\n")
		b.WriteString(text + " " + itoa(i) + "\n\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}

func ts(sec int) string {
	h, m, s := sec/3600, (sec/60)%60, sec%60
	two := func(v int) string {
		if v < 10 {
			return "0" + itoa(v)
		}
		return itoa(v)
	}
	return two(h) + ":" + two(m) + ":" + two(s) + ",000"
}

func TestExtractTracks_SinglePassAndHead(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not available")
	}
	dir := t.TempDir()

	frSRT := filepath.Join(dir, "fr.srt")
	enSRT := filepath.Join(dir, "en.srt")
	writeSRT(t, frSRT, "Bonjour", 60) // cues up to ~120s
	writeSRT(t, enSRT, "Hello", 60)

	video := filepath.Join(dir, "in.mkv")
	build := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
		"-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=140",
		"-i", frSRT, "-i", enSRT,
		"-map", "0:v", "-map", "1", "-map", "2",
		"-c:v", "libx264", "-preset", "ultrafast", "-c:s", "srt",
		"-metadata:s:s:0", "language=fra", "-metadata:s:s:1", "language=eng",
		video)
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building fixture failed: %v\n%s", err, out)
	}

	tracks := []plannedTrack{
		{typedIndex: 0, key: "fr", path: filepath.Join(dir, "out.fr.vtt")},
		{typedIndex: 1, key: "en", path: filepath.Join(dir, "out.en.vtt")},
	}

	// One pass must produce BOTH files.
	if err := extractTracks(video, tracks, 0); err != nil {
		t.Fatalf("full extraction: %v", err)
	}
	fullFr := readCues(t, tracks[0].path)
	fullEn := readCues(t, tracks[1].path)
	if fullFr != 60 || fullEn != 60 {
		t.Fatalf("expected 60 cues per track, got fr=%d en=%d", fullFr, fullEn)
	}
	if !strings.Contains(readFile(t, tracks[0].path), "Bonjour") {
		t.Error("French track holds the wrong stream")
	}
	if !strings.Contains(readFile(t, tracks[1].path), "Hello") {
		t.Error("English track holds the wrong stream")
	}

	// The head pass must be a strict, valid prefix — that is what makes it safe
	// to publish before the complete pass lands.
	for _, tr := range tracks {
		os.Remove(tr.path)
	}
	if err := extractTracks(video, tracks, 30); err != nil {
		t.Fatalf("head extraction: %v", err)
	}
	head := readCues(t, tracks[0].path)
	if head == 0 || head >= fullFr {
		t.Fatalf("head pass should yield a strict subset of cues, got %d of %d", head, fullFr)
	}
	if !strings.HasPrefix(readFile(t, tracks[0].path), "WEBVTT") {
		t.Error("head output is not a valid WebVTT document")
	}
}

func TestExtractTracks_LeavesNoTempFileOnFailure(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not available")
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "out.fr.vtt")

	err := extractTracks(filepath.Join(dir, "does-not-exist.mkv"),
		[]plannedTrack{{typedIndex: 0, key: "fr", path: out}}, 0)
	if err == nil {
		t.Fatal("expected an error for a missing input")
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp.vtt") {
			t.Errorf("temp file %q survived a failed extraction", e.Name())
		}
	}
	if _, statErr := os.Stat(out); statErr == nil {
		t.Error("a failed extraction must not publish an output file")
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return string(b)
}

func readCues(t *testing.T, path string) int {
	t.Helper()
	return strings.Count(readFile(t, path), " --> ")
}
