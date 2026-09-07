package streaming

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The unit tests assert what the command line SAYS. This one asserts what
// FFmpeg does when handed it, which is a different question and the one that
// has actually been getting answered wrong: every codec/container combination
// this package refuses exists because some pairing made FFmpeg exit before its
// first segment, and no amount of argument-shape testing catches that.
//
// It needs a real media file, so it is opt-in:
//
//	ONYX_IT_MEDIA=/path/to/file.mkv go test ./streaming/ -run Integration -v
//
// Generate a suitable one (HEVC 10-bit + E-AC-3 5.1 + stereo AAC) with:
//
//	ffmpeg -f lavfi -i testsrc=d=8:s=1920x1080:r=24 -f lavfi -i sine=d=8 \
//	  -filter_complex "[1:a][1:a][1:a][1:a][1:a][1:a]amerge=inputs=6[a]" \
//	  -map 0:v -map "[a]" -c:v libx265 -pix_fmt yuv420p10le -c:a eac3 out.mkv
func integrationMedia(t *testing.T) string {
	t.Helper()
	path := os.Getenv("ONYX_IT_MEDIA")
	if path == "" {
		t.Skip("set ONYX_IT_MEDIA to a media file to run the FFmpeg integration tests")
	}
	if _, err := os.Stat(path); err != nil {
		t.Skipf("ONYX_IT_MEDIA is not readable: %v", err)
	}
	return path
}

// runSession builds the command for a set of capabilities and runs it until it
// has produced segments, returning the temp dir it wrote into.
func runSession(t *testing.T, media string, caps Capabilities, quality string) (string, *ProbeResult) {
	t.Helper()

	probe, err := ProbeTracks(media)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	tmp := t.TempDir()
	audioIdxs := SelectAudioRenditions(probe, 0)
	plan := PlanVideo(probe, quality, false, 0, 0, caps)
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:         media,
		Quality:           quality,
		TmpDir:            tmp,
		Probe:             probe,
		SegmentDuration:   2,
		AudioTypedIndexes: audioIdxs,
		Video:             plan,
		Caps:              caps,
	})
	t.Logf("video plan: copy=%v tonemap=%v reason=%q", plan.Copy, plan.Tonemap, plan.Reason)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("ffmpeg start: %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	// The first video segment is what proves the muxer accepted every stream.
	// A refused codec kills FFmpeg while it writes the header, before this.
	deadline := time.Now().Add(60 * time.Second)
	want := filepath.Join(tmp, "stream_0_000"+caps.Container.SegmentExt())
	for time.Now().Before(deadline) {
		if _, err := os.Stat(want); err == nil {
			return tmp, probe
		}
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("no first segment after 60s\nargs: ffmpeg %s\nstderr:\n%s",
		strings.Join(args, " "), stderr.String())
	return "", nil
}

// probeOutput reads back what actually landed in a produced segment.
func probeOutput(t *testing.T, dir, name string) *ProbeResult {
	t.Helper()
	// An fMP4 media segment is not self-describing: its codec parameters live in
	// the initialisation segment. Concatenating the two is what makes the result
	// probeable, and it is exactly what a player does with EXT-X-MAP.
	path := filepath.Join(dir, name)
	if strings.HasSuffix(name, ".m4s") {
		// Each variant has its own initialisation segment — init_0.mp4 for the
		// video, init_1.mp4 for the first audio rendition — because they hold
		// different codec parameters. Pairing a segment with the wrong one
		// produces a file ffprobe reads as having no streams at all.
		variant := strings.TrimPrefix(strings.SplitN(name, "_", 3)[1], "")
		init, err := os.ReadFile(filepath.Join(dir, "init_"+variant+".mp4"))
		if err != nil {
			t.Fatalf("no init segment: %v", err)
		}
		seg, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("no media segment: %v", err)
		}
		joined := filepath.Join(t.TempDir(), "joined.mp4")
		if err := os.WriteFile(joined, append(init, seg...), 0o600); err != nil {
			t.Fatalf("join: %v", err)
		}
		path = joined
	}
	out, err := ProbeTracks(path)
	if err != nil {
		t.Fatalf("probe output: %v", err)
	}
	return out
}

// TestIntegration_SurroundClientGetsTheFileUntouched is the whole point of the
// capability negotiation: a client that can decode what the file holds should
// receive it, not a re-encoded stereo approximation of it.
func TestIntegration_SurroundClientGetsTheFileUntouched(t *testing.T) {
	media := integrationMedia(t)
	caps := Capabilities{
		Container:        ContainerFMP4,
		VideoCodecs:      map[string]bool{"h264": true, "hevc": true, "av1": true},
		AudioCodecs:      map[string]bool{"aac": true, "ac3": true, "eac3": true},
		MaxAudioChannels: 8,
		MaxVideoBitDepth: 10,
		HDR:              true,
	}
	dir, src := runSession(t, media, caps, "2160p")

	if _, err := os.Stat(filepath.Join(dir, "init_0.mp4")); err != nil {
		t.Errorf("fMP4 sessions must publish an initialisation segment: %v", err)
	}

	got := probeOutput(t, dir, "stream_0_000.m4s")
	if got.Video == nil {
		t.Fatal("no video stream in the produced segment")
	}
	if got.Video.Codec != src.Video.Codec {
		t.Errorf("video codec = %q, want the source's %q — this should have been a copy",
			got.Video.Codec, src.Video.Codec)
	}
	if got.Video.PixFmt != src.Video.PixFmt {
		t.Errorf("pix_fmt = %q, want the source's %q", got.Video.PixFmt, src.Video.PixFmt)
	}

	// And the surround track keeps its channels rather than being folded.
	if len(src.Audio) > 0 && src.Audio[0].Channels > 2 {
		aud := probeOutput(t, dir, "stream_1_000.m4s")
		if len(aud.Audio) == 0 {
			t.Fatal("no audio stream in the produced audio segment")
		}
		if aud.Audio[0].Channels != src.Audio[0].Channels {
			t.Errorf("audio channels = %d, want the source's %d",
				aud.Audio[0].Channels, src.Audio[0].Channels)
		}
		if aud.Audio[0].Codec != src.Audio[0].Codec {
			t.Errorf("audio codec = %q, want the source's %q",
				aud.Audio[0].Codec, src.Audio[0].Codec)
		}
	}
}

// TestIntegration_LegacyClientStillGetsAPlayableStream guards the other half:
// widening what a capable client receives must not break the browser this
// server was written for.
func TestIntegration_LegacyClientStillGetsAPlayableStream(t *testing.T) {
	media := integrationMedia(t)
	dir, _ := runSession(t, media, LegacyCapabilities(), "720p")

	got := probeOutput(t, dir, "stream_0_000.ts")
	if got.Video == nil {
		t.Fatal("no video stream in the produced segment")
	}
	if got.Video.Codec != "h264" {
		t.Errorf("video codec = %q, want h264 for a legacy client", got.Video.Codec)
	}
	if !got.Video.EightBit420() {
		t.Errorf("pix_fmt = %q, want plain 8-bit 4:2:0", got.Video.PixFmt)
	}
	aud := probeOutput(t, dir, "stream_1_000.ts")
	if len(aud.Audio) == 0 {
		t.Fatal("no audio stream produced")
	}
	if aud.Audio[0].Codec != "aac" || aud.Audio[0].Channels != 2 {
		t.Errorf("audio = %s %dch, want stereo AAC",
			aud.Audio[0].Codec, aud.Audio[0].Channels)
	}
}
