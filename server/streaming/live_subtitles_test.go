package streaming

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestLiveSubtitleTracks_OnlyTextThatConvertsSafely(t *testing.T) {
	// Une sortie que FFmpeg refuse d'ouvrir tue la session entière, image
	// comprise : un sous-titre inconnu ne doit jamais y entrer.
	probe := &ProbeResult{Subtitles: []SubtitleStreamInfo{
		{TypedIndex: 0, Codec: "subrip"},
		{TypedIndex: 1, Codec: "hdmv_pgs_subtitle", Image: true},
		{TypedIndex: 2, Codec: "ass"},
		{TypedIndex: 3, Codec: "eia_608"},
		{TypedIndex: 4, Codec: "mov_text"},
	}}
	if got, want := LiveSubtitleTracks(probe), []int{0, 2, 4}; !reflect.DeepEqual(got, want) {
		t.Errorf("LiveSubtitleTracks = %v, want %v", got, want)
	}
	if got := LiveSubtitleTracks(nil); got != nil {
		t.Errorf("no probe must mean no track, got %v", got)
	}
}

func TestLiveSubtitleTracks_IsBounded(t *testing.T) {
	probe := &ProbeResult{}
	for i := 0; i < maxLiveSubtitles+5; i++ {
		probe.Subtitles = append(probe.Subtitles, SubtitleStreamInfo{TypedIndex: i, Codec: "subrip"})
	}
	if got := len(LiveSubtitleTracks(probe)); got != maxLiveSubtitles {
		t.Errorf("%d tracks written, want at most %d", got, maxLiveSubtitles)
	}
}

func TestIsLiveSubtitleFile(t *testing.T) {
	for name, want := range map[string]bool{
		"sub_0.vtt":     true,
		"sub_12.vtt":    true,
		"sub_.vtt":      false,
		"sub_x.vtt":     false,
		"sub_1.m3u8":    false,
		"stream_0.m3u8": false,
		"fr.vtt":        false,
	} {
		if got := isLiveSubtitleFile(name); got != want {
			t.Errorf("isLiveSubtitleFile(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestBuildFFmpegArgs_TextSubtitlesAreSeparateOutputsAfterTheStream(t *testing.T) {
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:       "/tmp/in.mkv",
		Quality:         "720p",
		TmpDir:          "/tmp/out",
		Probe:           probeWith(1920, 1080, 24),
		SegmentDuration: 2,
		LiveSubtitles:   []int{0, 2},
	})
	joined := strings.Join(args, " ")

	// Le flux HLS reste sans sous-titres ; les WebVTT viennent après sa
	// playlist, pour que leurs options ne s'appliquent qu'à eux.
	playlist := strings.Index(joined, "stream_%v.m3u8")
	first := strings.Index(joined, "-map 0:s:0")
	if playlist < 0 || first < playlist {
		t.Fatalf("subtitle outputs must follow the HLS output:\n%s", joined)
	}
	if !hasArg(args, "-sn") {
		t.Error("the HLS output itself must carry no subtitle")
	}
	for _, want := range []string{
		"-map 0:s:0 -c:s webvtt -flush_packets 1 -f webvtt " + filepath.Join("/tmp/out", "sub_0.vtt"),
		"-map 0:s:2 -c:s webvtt -flush_packets 1 -f webvtt " + filepath.Join("/tmp/out", "sub_2.vtt"),
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing output %q in:\n%s", want, joined)
		}
	}

	// Sans piste, la commande est celle d'avant l'ADR-0031.
	without := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "720p", TmpDir: "/tmp/out",
		Probe: probeWith(1920, 1080, 24), SegmentDuration: 2,
	})
	if strings.Contains(strings.Join(without, " "), "webvtt") {
		t.Error("a session without text track must not write any WebVTT")
	}
}

func TestServeLiveSubtitle_ServesOnlyWhatFollows(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub_0.vtt")

	get := func(rangeHeader string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/sub_0.vtt", nil)
		if rangeHeader != "" {
			req.Header.Set("Range", rangeHeader)
		}
		rec := httptest.NewRecorder()
		serveLiveSubtitle(rec, req, path)
		return rec
	}

	// Pas encore de réplique : FFmpeg n'a pas créé le fichier.
	if rec := get(""); rec.Code != http.StatusNoContent {
		t.Fatalf("missing file: status %d, want 204", rec.Code)
	}

	body := "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBonjour\n\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if rec := get(""); rec.Code != http.StatusOK || rec.Body.String() != body {
		t.Fatalf("whole file: %d %q", rec.Code, rec.Body.String())
	}
	if rec := get("bytes=8-"); rec.Code != http.StatusPartialContent || rec.Body.String() != body[8:] {
		t.Fatalf("tail: %d %q", rec.Code, rec.Body.String())
	}
	// Rien de neuf depuis la dernière lecture.
	if rec := get("bytes=" + strconv.Itoa(len(body)) + "-"); rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("nothing new: status %d, want 416", rec.Code)
	}
}

// --- Contre un vrai FFmpeg

// TestSessionWritesSubtitlesOnItsOwnClock est celui qui compte : une session
// reprise en cours de film écrit ses répliques sur l'horloge de ses segments,
// sans ce qui précède le point de reprise, et pour chaque piste texte.
func TestSessionWritesSubtitlesOnItsOwnClock(t *testing.T) {
	if testing.Short() {
		t.Skip("runs ffmpeg")
	}
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}

	dir := t.TempDir()
	srt := filepath.Join(dir, "fr.srt")
	if err := os.WriteFile(srt, []byte(
		"1\n00:00:01,000 --> 00:00:02,000\nAvant la reprise\n\n"+
			"2\n00:00:06,000 --> 00:00:07,500\nApres la reprise\n\n"+
			"3\n00:00:09,000 --> 00:00:10,000\nFin\n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(dir, "source.mkv")
	// Chaque FFmpeg de ce test a une échéance. -t est une option de sortie
	// ici : placé après la source lavfi, il s'appliquerait à l'entrée suivante
	// et la mire, infinie, serait encodée jusqu'à remplir le disque.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	build := exec.CommandContext(ctx, "ffmpeg", "-y", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24",
		"-i", srt, "-i", srt,
		"-map", "0:v", "-map", "1:s", "-map", "2:s",
		"-t", "12",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "24",
		"-c:s:0", "srt", "-c:s:1", "ass", source)
	if out, err := build.CombinedOutput(); err != nil {
		t.Skipf("could not build a source: %v %s", err, out)
	}

	probe, err := ProbeTracks(source)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	tracks := LiveSubtitleTracks(probe)
	if !reflect.DeepEqual(tracks, []int{0, 1}) {
		t.Fatalf("text tracks = %v, want [0 1]", tracks)
	}

	out := filepath.Join(dir, "session")
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:       source,
		Quality:         "480p",
		StartSeconds:    4,
		TmpDir:          out,
		Probe:           probe,
		SegmentDuration: 2,
		LiveSubtitles:   tracks,
	})
	if output, err := exec.CommandContext(ctx, "ffmpeg", args...).CombinedOutput(); err != nil {
		t.Fatalf("the session refused its subtitle outputs: %v\n%s", err, output)
	}
	if _, err := os.Stat(filepath.Join(out, "stream_0.m3u8")); err != nil {
		t.Fatalf("the video stream must still be written: %v", err)
	}

	for _, typedIndex := range tracks {
		data, err := os.ReadFile(filepath.Join(out, LiveSubtitleFileName(typedIndex)))
		if err != nil {
			t.Fatalf("track %d: %v", typedIndex, err)
		}
		vtt := string(data)
		if !strings.HasPrefix(vtt, "WEBVTT") {
			t.Errorf("track %d is not WebVTT:\n%s", typedIndex, vtt)
		}
		if strings.Contains(vtt, "Avant la reprise") {
			t.Errorf("track %d kept a cue from before the resume point:\n%s", typedIndex, vtt)
		}
		// 6 s dans le film, repris à 4 s : 2 s sur l'horloge de la session.
		if !strings.Contains(vtt, "00:02.000 --> ") || !strings.Contains(vtt, "Apres la reprise") {
			t.Errorf("track %d is not on the session clock:\n%s", typedIndex, vtt)
		}
	}
}
