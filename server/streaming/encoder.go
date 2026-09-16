package streaming

import (
	"context"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Which H.264 encoder a session uses.
//
// The default is unchanged: libx264, on the CPU. Hardware encoding is offered,
// not assumed, because "hardware is faster" turns out not to be a property of
// hardware — it is a property of a particular box. Measured on an 8-core Apple
// Silicon machine, 20s of 2160p:
//
//	libx264 ultrafast   1.95s wall   10.4s CPU   (10.3x real-time, ~5.3 cores)
//	libx264 veryfast    4.41s wall   30.2s CPU   ( 4.5x real-time, ~6.8 cores)
//	h264_videotoolbox   8.92s wall    3.7s CPU   ( 2.2x real-time, ~0.4 cores)
//
// The hardware encoder spends a fourteenth of the CPU and is four times slower
// at it. Which of those matters depends on the host: on a machine with cores to
// spare, libx264 finishes sooner and more sessions fit; on the CPU-only Xeon
// this server was written against — where the note on the 2160p preset records
// veryfast measuring *below* real-time on a genuine HEVC source — an encoder
// that needs almost no CPU is the difference between transcoding and not.
//
// So the choice is the operator's, and the measurement is theirs to make. See
// the ADR for the one-line benchmark.

// VideoEncoder is an encoder this server can drive.
type VideoEncoder struct {
	// Name is the FFmpeg encoder name.
	Name string
	// Hardware says the encoding leaves the CPU.
	Hardware bool
	// PixelFormat is what the filter chain must hand it.
	PixelFormat string
	// rateControl builds the flags that set quality and bitrate, which is where
	// the encoders differ most: libx264 targets a quality and caps the result,
	// while the hardware encoders take a bitrate and hold it.
	rateControl func(preset qualityPreset) []string
}

// softwareEncoder is the default and the fallback. Its flags are exactly the
// ones this server has always sent.
var softwareEncoder = VideoEncoder{
	Name:        "libx264",
	PixelFormat: "yuv420p",
	rateControl: func(preset qualityPreset) []string {
		return []string{
			"-preset", encoderPresetFor(preset),
			// CRF is the quality target; maxrate/bufsize are the VBV ceiling
			// that keeps a detailed scene from bursting past what the link
			// carries.
			"-crf", "23",
			"-b:v", "0",
			"-maxrate", preset.VideoBitrate,
			"-bufsize", doubleBitrate(preset.VideoBitrate),
			"-threads", strconv.Itoa(maxEncoderThreads),
		}
	},
}

// hardwareEncoders are tried in this order. They have one thing in common that
// keeps this change small: all three accept ordinary software frames and upload
// them internally, so the filter chain — scaling, tone mapping, burned-in
// subtitles — is the same as it has always been.
//
// VAAPI is deliberately absent. It is the one that cannot take software frames:
// it needs a device opened up front and a `hwupload` appended to every filter
// chain, which is a change to the filter graph rather than to a flag. Worth
// doing, separately.
var hardwareEncoders = []VideoEncoder{
	{
		Name:        "h264_videotoolbox",
		Hardware:    true,
		PixelFormat: "yuv420p",
		rateControl: func(preset qualityPreset) []string {
			return []string{
				// No CRF here: VideoToolbox takes a bitrate and holds it. The
				// stream therefore sits at the tier's number rather than under
				// it, which is what the menu promised anyway.
				"-b:v", preset.VideoBitrate,
				"-maxrate", preset.VideoBitrate,
				"-bufsize", doubleBitrate(preset.VideoBitrate),
				// Let it fall back to its own software path rather than fail the
				// session outright if the hardware block is unavailable.
				"-allow_sw", "1",
			}
		},
	},
	{
		Name:        "h264_nvenc",
		Hardware:    true,
		PixelFormat: "yuv420p",
		rateControl: func(preset qualityPreset) []string {
			return []string{
				"-rc", "vbr",
				"-b:v", preset.VideoBitrate,
				"-maxrate", preset.VideoBitrate,
				"-bufsize", doubleBitrate(preset.VideoBitrate),
				// p4 is NVENC's middle preset: the quality-per-bit of the slower
				// ones costs wall-clock this path does not have to spare.
				"-preset", "p4",
				"-no-scenecut", "1",
			}
		},
	},
	{
		Name:     "h264_qsv",
		Hardware: true,
		// Quick Sync works in NV12; handing it yuv420p makes FFmpeg insert a
		// conversion on every frame.
		PixelFormat: "nv12",
		rateControl: func(preset qualityPreset) []string {
			return []string{
				"-b:v", preset.VideoBitrate,
				"-maxrate", preset.VideoBitrate,
				"-bufsize", doubleBitrate(preset.VideoBitrate),
				"-preset", "veryfast",
			}
		},
	},
}

// videoEncoderOnce caches the answer: detection runs FFmpeg, and the answer
// cannot change while the process lives.
var (
	videoEncoderOnce sync.Once
	resolvedEncoder  VideoEncoder
)

// SelectedVideoEncoder is the encoder every session uses.
func SelectedVideoEncoder() VideoEncoder {
	videoEncoderOnce.Do(func() {
		resolvedEncoder = detectVideoEncoder(encoderWorks)
		log.Printf("Streaming: video encoder %s (hardware=%v)", resolvedEncoder.Name, resolvedEncoder.Hardware)
	})
	return resolvedEncoder
}

// detectVideoEncoder resolves VIDEO_ENCODER. It takes the probe as an argument
// so the decision can be tested without an FFmpeg on the machine running the
// tests.
//
// Unset means libx264, exactly as before: a server that is transcoding happily
// today must not change encoder because it was upgraded.
func detectVideoEncoder(works func(name string) bool) VideoEncoder {
	requested := strings.TrimSpace(os.Getenv("VIDEO_ENCODER"))
	switch requested {
	case "", softwareEncoder.Name:
		return softwareEncoder
	case "auto":
		for _, candidate := range hardwareEncoders {
			if works(candidate.Name) {
				return candidate
			}
		}
		log.Println("Streaming: VIDEO_ENCODER=auto found no working hardware encoder, using libx264")
		return softwareEncoder
	}

	for _, candidate := range hardwareEncoders {
		if candidate.Name != requested {
			continue
		}
		if works(candidate.Name) {
			return candidate
		}
		// Naming an encoder that does not run is worth a loud line: the operator
		// asked for it, and silently encoding on the CPU would look like the
		// hardware was simply slow.
		log.Printf("Streaming: VIDEO_ENCODER=%s is not usable on this host, using libx264", requested)
		return softwareEncoder
	}

	log.Printf("Streaming: VIDEO_ENCODER=%q is not an encoder this server drives, using libx264", requested)
	return softwareEncoder
}

// encoderWorks encodes a single frame and throws it away.
//
// Asking `ffmpeg -encoders` only says what was compiled in, which is not the
// question: an FFmpeg built with NVENC on a machine with no NVIDIA card lists
// h264_nvenc and fails the moment a session starts. One frame costs
// milliseconds and answers the question that matters.
func encoderWorks(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=320x240:rate=1",
		"-frames:v", "1",
		"-c:v", name,
		"-f", "null", "-",
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		log.Printf("Streaming: encoder %s unusable: %v %s", name, err, strings.TrimSpace(string(output)))
		return false
	}
	return true
}

// encoder resolves what the options asked for, defaulting to software.
func (o TranscodeOptions) encoder() VideoEncoder {
	if o.Encoder.Name == "" || o.Encoder.rateControl == nil {
		return softwareEncoder
	}
	return o.Encoder
}
