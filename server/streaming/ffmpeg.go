package streaming

import (
	"fmt"
	"strconv"
)

// qualityPresets maps quality labels to resolution dimensions.
var qualityPresets = map[string]struct{ W, H int }{
	"360p":  {640, 360},
	"480p":  {854, 480},
	"720p":  {1280, 720},
	"1080p": {1920, 1080},
}

// presetFor returns the resolution for a quality label, defaulting to 720p.
func presetFor(quality string) struct{ W, H int } {
	if p, ok := qualityPresets[quality]; ok {
		return p
	}
	return qualityPresets["720p"]
}

// TranscodeOptions describes everything needed to build an HLS FFmpeg command.
type TranscodeOptions struct {
	InputPath    string
	Quality      string
	StartSeconds int
	TmpDir       string
	Probe        *ProbeResult
	// SegmentDuration is the HLS target segment length in seconds.
	SegmentDuration int
	// AudioTypedIndex is the single 0:a:N audio track to transcode (the language
	// the client requested). Changing it requires a fresh session.
	AudioTypedIndex int
}

// BuildFFmpegArgs constructs the FFmpeg command-line for an HLS transcode.
//
// Design (video + a SINGLE audio track — deliberately lean):
//   - One H.264 video rendition (8-bit yuv420p, ultrafast) — the only heavy work.
//   - Exactly ONE audio track (the requested AudioTypedIndex) transcoded to AAC
//     and muxed into the same segments, keeping CPU usage minimal. Switching
//     language is a client-driven session restart, not a multi-rendition stream.
//   - NO subtitles (-sn). Subtitles live entirely out of band as pre-extracted
//     .vtt files served separately and injected by the client as external tracks.
//
// FFmpeg writes master.m3u8 + stream_0.m3u8 (+ stream_0_%03d.ts) into TmpDir.
// The variant URI stays relative, so the player resolves it against the master
// URL and no server-side playlist rewriting is required.
func BuildFFmpegArgs(opt TranscodeOptions) []string {
	preset := presetFor(opt.Quality)
	segDur := opt.SegmentDuration
	if segDur <= 0 {
		segDur = 4
	}

	args := []string{"-hide_banner", "-loglevel", "error"}

	// Single keyframe-accurate input seek; on the input (before -i) so the HLS
	// timeline resets to ~0 at the requested start position.
	if opt.StartSeconds > 0 {
		args = append(args, "-ss", strconv.Itoa(opt.StartSeconds))
	}
	args = append(args, "-i", opt.InputPath)

	// --- Mapping: video + the single requested audio track (no subtitles) ---
	audioIdx := opt.AudioTypedIndex
	if audioIdx < 0 {
		audioIdx = 0
	}
	args = append(args,
		"-map", "0:v:0",
		"-map", fmt.Sprintf("0:a:%d?", audioIdx),
		"-vf", fmt.Sprintf("scale=%d:%d:flags=fast_bilinear", preset.W, preset.H),
	)

	// --- Codecs ---
	// ultrafast + zerolatency removes lookahead/B-frames so the first segments
	// appear almost immediately on a CPU-only host. Force 8-bit 4:2:0 so 10-bit
	// HEVC sources don't yield a "High 10" H.264 stream most clients can't decode.
	args = append(args,
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-tune", "zerolatency",
		"-crf", "23",
		"-pix_fmt", "yuv420p",
		"-g", strconv.Itoa(segDur*24),
		"-force_key_frames", fmt.Sprintf("expr:gte(t,n_forced*%d)", segDur),
		"-threads", "0",
	)
	args = append(args, "-c:a", "aac", "-b:a", "160k", "-ac", "2")
	args = append(args, "-sn", "-max_muxing_queue_size", "1024")

	// One muxed variant (video + audio). The master playlist + stream_0.* naming
	// is preserved so the client and the segment-throttling logic are unchanged.
	args = append(args,
		"-f", "hls",
		"-hls_time", strconv.Itoa(segDur),
		"-hls_list_size", "0",
		"-hls_flags", "independent_segments+temp_file",
		"-master_pl_name", "master.m3u8",
		"-var_stream_map", "v:0,a:0",
		"-hls_segment_filename", opt.TmpDir+"/stream_%v_%03d.ts",
		opt.TmpDir+"/stream_%v.m3u8",
	)

	return args
}

// EstimateBandwidth returns a rough bandwidth estimate (bits/s) for a quality.
func EstimateBandwidth(quality string) int {
	bandwidths := map[string]int{
		"360p":  800000,
		"480p":  1400000,
		"720p":  2800000,
		"1080p": 5000000,
	}
	if bw, ok := bandwidths[quality]; ok {
		return bw
	}
	return 2800000
}
