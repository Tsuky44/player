package streaming

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func argsFor(encoder VideoEncoder, quality string) []string {
	return BuildFFmpegArgs(TranscodeOptions{
		InputPath:         "in.mkv",
		Quality:           quality,
		TmpDir:            "/tmp/session",
		Probe:             &ProbeResult{Video: &VideoStreamInfo{Width: 3840, Height: 2160, Codec: "hevc", FrameRate: 24}},
		SegmentDuration:   4,
		AudioTypedIndexes: []int{0},
		Encoder:           encoder,
	})
}

func hasFlag(args []string, flag, value string) bool {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

func hasAnyFlag(args []string, flag string) bool {
	for _, arg := range args {
		if arg == flag {
			return true
		}
	}
	return false
}

// --- Selection

// Unset means libx264, exactly as before. A server transcoding happily today
// must not change encoder because it was upgraded.
func TestEncoderDefaultsToSoftware(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "")
	never := func(string) bool { return false }
	if got := detectVideoEncoder(never); got.Name != softwareEncoder.Name {
		t.Errorf("unset VIDEO_ENCODER selected %q, want libx264", got.Name)
	}
}

func TestEncoderAutoTakesTheFirstThatRuns(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "auto")
	// Pretend the first candidate is compiled in but has no device behind it,
	// which is exactly what an FFmpeg built with NVENC does on a host with no
	// NVIDIA card.
	onlyQSV := func(name string) bool { return name == "h264_qsv" }
	if got := detectVideoEncoder(onlyQSV); got.Name != "h264_qsv" {
		t.Errorf("auto selected %q, want h264_qsv", got.Name)
	}
}

func TestEncoderAutoFallsBackWhenNothingRuns(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "auto")
	never := func(string) bool { return false }
	if got := detectVideoEncoder(never); got.Name != softwareEncoder.Name {
		t.Errorf("auto with no working hardware selected %q, want libx264", got.Name)
	}
}

// Naming an encoder that does not run must not fail the server, and must not
// pretend either: it falls back and says so.
func TestNamedEncoderThatCannotRunFallsBack(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "h264_nvenc")
	never := func(string) bool { return false }
	if got := detectVideoEncoder(never); got.Name != softwareEncoder.Name {
		t.Errorf("unusable named encoder selected %q, want libx264", got.Name)
	}
}

func TestNamedEncoderIsHonouredWhenItRuns(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "h264_nvenc")
	always := func(string) bool { return true }
	got := detectVideoEncoder(always)
	if got.Name != "h264_nvenc" || !got.Hardware {
		t.Errorf("named encoder selected %+v, want h264_nvenc as hardware", got)
	}
}

func TestUnknownEncoderNameFallsBack(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "h264_something_else")
	always := func(string) bool { return true }
	if got := detectVideoEncoder(always); got.Name != softwareEncoder.Name {
		t.Errorf("unknown name selected %q, want libx264", got.Name)
	}
}

// Asking for libx264 by name must not run a probe at all.
func TestSoftwareByNameSkipsProbing(t *testing.T) {
	t.Setenv("VIDEO_ENCODER", "libx264")
	probed := false
	watch := func(string) bool { probed = true; return true }
	if got := detectVideoEncoder(watch); got.Name != softwareEncoder.Name {
		t.Errorf("selected %q, want libx264", got.Name)
	}
	if probed {
		t.Error("probed an encoder although libx264 was named")
	}
}

// --- Arguments

// The software command is what this server has always sent. Pinning it is the
// point: hardware encoding is an addition, not a rewrite of the working path.
func TestSoftwareArgsAreUnchanged(t *testing.T) {
	args := argsFor(softwareEncoder, "1080p")
	for _, want := range [][2]string{
		{"-c:v", "libx264"},
		{"-pix_fmt", "yuv420p"},
		{"-profile:v", "high"},
		{"-crf", "23"},
		{"-b:v", "0"},
		{"-maxrate", "6M"},
		{"-bufsize", "12M"},
		{"-preset", "veryfast"},
		{"-sc_threshold", "0"},
	} {
		if !hasFlag(args, want[0], want[1]) {
			t.Errorf("software command lost %s %s", want[0], want[1])
		}
	}
}

// A zero-value Encoder means libx264, so every caller written before hardware
// encoding existed builds the command it always did.
func TestZeroEncoderMeansSoftware(t *testing.T) {
	if !hasFlag(argsFor(VideoEncoder{}, "1080p"), "-c:v", "libx264") {
		t.Error("the zero encoder did not build a libx264 command")
	}
}

// x264 spells "put no IDR where I did not ask for one" in options the hardware
// encoders do not take. FFmpeg's own force_key_frames reaches all of them, and
// it is what actually pins the segment boundaries.
func TestX264OnlyFlagsStayOffHardware(t *testing.T) {
	for _, encoder := range hardwareEncoders {
		args := argsFor(encoder, "1080p")
		for _, forbidden := range []string{"-sc_threshold", "-keyint_min", "-crf", "-threads"} {
			if hasAnyFlag(args, forbidden) {
				t.Errorf("%s was given %s, which it does not take", encoder.Name, forbidden)
			}
		}
		if !hasAnyFlag(args, "-force_key_frames") {
			t.Errorf("%s lost force_key_frames, so segments would drift", encoder.Name)
		}
		if !hasAnyFlag(args, "-g") {
			t.Errorf("%s lost its GOP size", encoder.Name)
		}
	}
}

// Every encoder must be told the tier's ceiling, whatever its spelling.
func TestEveryEncoderRespectsTheTierBitrate(t *testing.T) {
	for _, encoder := range append([]VideoEncoder{softwareEncoder}, hardwareEncoders...) {
		args := argsFor(encoder, "720p")
		if !hasFlag(args, "-maxrate", "3500k") {
			t.Errorf("%s was not given the 720p ceiling", encoder.Name)
		}
		if !hasFlag(args, "-bufsize", "7000k") {
			t.Errorf("%s was not given the 720p buffer", encoder.Name)
		}
	}
}

// Quick Sync works in NV12; handing it yuv420p makes FFmpeg convert every frame.
func TestQuickSyncAsksForNV12(t *testing.T) {
	for _, encoder := range hardwareEncoders {
		if encoder.Name != "h264_qsv" {
			continue
		}
		if !hasFlag(argsFor(encoder, "1080p"), "-pix_fmt", "nv12") {
			t.Error("h264_qsv was not asked for nv12")
		}
	}
}

// The copy path takes no encoder settings at all, hardware or not.
func TestCopyPathIgnoresTheEncoder(t *testing.T) {
	for _, encoder := range append([]VideoEncoder{softwareEncoder}, hardwareEncoders...) {
		args := BuildFFmpegArgs(TranscodeOptions{
			InputPath: "in.mkv", Quality: "1080p", TmpDir: "/tmp/s",
			Probe:           &ProbeResult{Video: &VideoStreamInfo{Width: 1920, Height: 1080, Codec: "h264"}},
			SegmentDuration: 4, AudioTypedIndexes: []int{0},
			Encoder: encoder,
			Video:   VideoPlan{Copy: true},
		})
		if !hasFlag(args, "-c:v", "copy") {
			t.Errorf("%s: the copy path stopped copying", encoder.Name)
		}
		if hasAnyFlag(args, "-b:v") || hasAnyFlag(args, "-maxrate") {
			t.Errorf("%s: the copy path was given encoder settings", encoder.Name)
		}
	}
}

// --- Against a real FFmpeg

// TestHardwareEncodersProduceAlignedSegments is the one that matters: a command
// this server would actually run, against whatever encoder this host has.
//
// Segment boundaries are the risk. Dropping keyint_min and sc_threshold for the
// hardware path is only safe if force_key_frames still lands a keyframe exactly
// on each boundary — otherwise segments drift, and seeking with them.
func TestHardwareEncodersProduceAlignedSegments(t *testing.T) {
	if testing.Short() {
		t.Skip("runs ffmpeg")
	}
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}

	tested := 0
	for _, encoder := range hardwareEncoders {
		if !encoderWorks(encoder.Name) {
			continue
		}
		tested++
		t.Run(encoder.Name, func(t *testing.T) {
			dir := t.TempDir()
			source := filepath.Join(dir, "source.mp4")
			build := exec.Command("ffmpeg", "-y", "-loglevel", "error",
				"-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "10",
				"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", source)
			if out, err := build.CombinedOutput(); err != nil {
				t.Skipf("could not build a source: %v %s", err, out)
			}

			args := BuildFFmpegArgs(TranscodeOptions{
				InputPath:         source,
				Quality:           "480p",
				TmpDir:            dir,
				Probe:             &ProbeResult{Video: &VideoStreamInfo{Width: 640, Height: 360, Codec: "h264", FrameRate: 24}},
				SegmentDuration:   4,
				AudioTypedIndexes: nil,
				Encoder:           encoder,
			})
			run := exec.Command("ffmpeg", args...)
			if out, err := run.CombinedOutput(); err != nil {
				t.Fatalf("%s refused the command: %v\n%s", encoder.Name, err, out)
			}

			// master.m3u8 lists the variants; the segments and their durations
			// are in the media playlist, which is the one this asserts on.
			playlist, err := os.ReadFile(filepath.Join(dir, "stream_0.m3u8"))
			if err != nil {
				entries, _ := os.ReadDir(dir)
				names := make([]string, 0, len(entries))
				for _, e := range entries {
					names = append(names, e.Name())
				}
				t.Fatalf("no media playlist among %v", names)
			}

			durations := 0
			for _, line := range strings.Split(string(playlist), "\n") {
				if !strings.HasPrefix(line, "#EXTINF:") {
					continue
				}
				durations++
				value := strings.TrimSuffix(strings.TrimPrefix(line, "#EXTINF:"), ",")
				// Every segment but the last must be the requested length. A
				// drifting boundary shows up here first.
				if durations < 3 && !strings.HasPrefix(value, "4.0") {
					t.Errorf("segment %d lasts %s, want 4.0", durations, value)
				}
			}
			if durations < 2 {
				t.Errorf("%s produced %d segments, want at least 2", encoder.Name, durations)
			}
		})
	}

	if tested == 0 {
		t.Skip("no hardware encoder on this host")
	}
}
