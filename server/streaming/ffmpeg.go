package streaming

import (
	"fmt"
	"strconv"
	"strings"
)

// qualityPreset describes a single HLS video rendition.
//
// Every preset carries a VideoBitrate ceiling. CRF alone is unbounded: on a
// detailed scene an "advertised 2.8 Mbps" 720p rendition can burst past 15 Mbps,
// which the client cannot anticipate — it just stalls. CRF is kept as the
// quality target, VideoBitrate/bufsize act as a VBV ceiling so the stream stays
// within what the link can actually carry.
type qualityPreset struct {
	W, H int
	// VideoBitrate caps the average/peak bitrate (VBV ceiling), e.g. "3500k".
	VideoBitrate string
	// AudioBitrate for the transcoded AAC track.
	AudioBitrate string
	// EncoderPreset overrides x264Preset for this tier. Empty means "use
	// x264Preset". Exists because CPU cost scales with pixel count: "veryfast"
	// has ample real-time margin at 1080p and below, but on a CPU-only host a
	// fresh 2160p session can start with zero buffer (any seek destroys the
	// existing one) and has to out-encode playback from a cold start — a preset
	// that is merely "usually fast enough" isn't good enough there.
	EncoderPreset string
}

// qualityPresets maps quality labels to resolution / bitrate profiles.
var qualityPresets = map[string]qualityPreset{
	"360p":  {W: 640, H: 360, VideoBitrate: "1M", AudioBitrate: "128k"},
	"480p":  {W: 854, H: 480, VideoBitrate: "1800k", AudioBitrate: "128k"},
	"720p":  {W: 1280, H: 720, VideoBitrate: "3500k", AudioBitrate: "160k"},
	"1080p": {W: 1920, H: 1080, VideoBitrate: "6M", AudioBitrate: "160k"},
	// 4K Light: full UHD resolution but capped so a medium connection
	// (~10–15 Mbps) can keep up without constant underruns.
	//
	// EncoderPreset is forced to "ultrafast" here, unlike every other tier.
	// Measured on the same 4K source, same CRF: veryfast completes 30s of
	// content in 23.1s (1.30x real-time) vs ultrafast's 8.5s (3.55x). 1.30x
	// looks fine until you subtract the decode cost of a real 10-bit HEVC
	// source and the weaker per-core throughput of an older CPU-only Xeon —
	// at which point it measures out below 1.0x, and a below-1.0x encoder can
	// never refill a buffer it has already fallen behind on. That is exactly
	// the failure mode a cold-started session hits right after a seek: no
	// buffer cushion, so it has to be faster than real-time from frame one or
	// it stalls forever. veryfast's extra ~2.4x bitrate cost at equal CRF
	// (measured on 1080p) is already absorbed by the VBV cap below, so
	// ultrafast's lower quality-per-bit here mostly shows up as "closer to the
	// bitrate ceiling more often", not as a broken stream.
	"2160p": {W: 3840, H: 2160, VideoBitrate: "12M", AudioBitrate: "192k", EncoderPreset: "ultrafast"},
}

// presetFor returns the profile for a quality label, defaulting to 720p.
func presetFor(quality string) qualityPreset {
	if p, ok := qualityPresets[quality]; ok {
		return p
	}
	return qualityPresets["720p"]
}

// x264Preset is the default libx264 speed/efficiency tradeoff, used by every
// quality tier unless its qualityPreset.EncoderPreset overrides it.
//
// "veryfast" rather than "ultrafast": measured on the same source at the same
// CRF, ultrafast emits ~2.4x the bitrate for only ~33% less encode time
// (18.8 Mbps vs 7.7 Mbps). On a CPU-only host the scarce resource at playback
// time is the network, not the cores — and the JIT throttler already keeps a
// 32s buffer ahead, so raw encode latency is not the constraint at these
// resolutions (see the 2160p override above for where that stops being true).
const x264Preset = "veryfast"

// encoderPresetFor resolves the effective libx264 preset for a quality tier.
func encoderPresetFor(preset qualityPreset) string {
	if preset.EncoderPreset != "" {
		return preset.EncoderPreset
	}
	return x264Preset
}

// maxEncoderThreads caps libx264 threads per session.
//
// The target host is a dual-socket Xeon: letting one session spread across both
// sockets costs more in cross-NUMA memory traffic than it gains in throughput,
// and starves any concurrent session. 16 threads saturate a single socket's
// worth of frame-threading while leaving room for a second stream.
const maxEncoderThreads = 16

// TranscodeOptions describes everything needed to build an HLS FFmpeg command.
type TranscodeOptions struct {
	InputPath    string
	Quality      string
	StartSeconds int
	TmpDir       string
	Probe        *ProbeResult
	// SegmentDuration is the HLS target segment length in seconds.
	SegmentDuration int
	// AudioTypedIndexes lists the source audio tracks (the N in 0:a:N) to publish
	// as HLS renditions, in master-playlist order. The client maps its canonical
	// audio index to a rendition position through this exact list, which /start
	// hands back as audio_map — so switching language is an mpv track change, not
	// a session rebuild.
	AudioTypedIndexes []int
	// BurnSubtitle enables rendering a bitmap subtitle into the video.
	//
	// PGS/VOBSUB subtitles are images, so unlike text tracks they cannot be
	// served out of band as WebVTT. Painting them into the picture is the only
	// way to offer them while transcoding — which is why turning one on or off
	// is the one subtitle change that does need a new session.
	//
	// It is a separate flag rather than a sentinel index so the zero value of
	// TranscodeOptions means "no burn-in": 0 is a perfectly valid stream index,
	// and a forgotten field would otherwise silently burn in 0:s:0.
	BurnSubtitle bool
	// BurnSubtitleTypedIndex is the bitmap subtitle stream (the N in 0:s:N) to
	// render, meaningful only when BurnSubtitle is set.
	BurnSubtitleTypedIndex int
	// CopyVideo repackages the source picture instead of re-encoding it.
	//
	// The expensive half of a transcode is the video: decode every frame, encode
	// every frame. When the browser can already decode what the file holds, none
	// of that is necessary — the compressed bytes only need to move from one
	// container into another, which costs I/O and nothing else. Measured against
	// the encoding path it is roughly fifty times cheaper, and the picture comes
	// out bit-identical to the source instead of a generation down.
	//
	// Only ever set by CanCopyVideo, which enforces the conditions that make it
	// safe. Audio is unaffected and still re-encoded when the browser needs it.
	CopyVideo bool
}

// CanCopyVideo reports whether the source picture can be repackaged untouched.
//
// Every condition here is a way the copy would reach the viewer broken rather
// than merely suboptimal, so the answer defaults to no:
//
//   - a codec the browser cannot decode is the whole point of transcoding;
//   - 10-bit H.264 decodes nowhere in a browser and fails *silently*, showing a
//     black picture with no error;
//   - copying bytes cannot resize them, so any scaling rules it out;
//   - burning a bitmap subtitle means painting on the frames, which means
//     decoding them;
//   - and the bitrate ceiling is the one non-technical limit: copying means
//     sending the file's own bitrate, so past a point the CPU saved is paid for
//     in stalling on the viewer's connection.
func CanCopyVideo(probe *ProbeResult, quality string, burn bool, sourceBitrateBps, ceilingBps int64) bool {
	if probe == nil || probe.Video == nil || burn {
		return false
	}
	switch strings.ToLower(probe.Video.Codec) {
	case "h264", "avc1", "vp8", "vp9", "av1":
	default:
		return false
	}
	if !probe.Video.EightBit() {
		return false
	}
	if buildScaleFilter(probe, presetFor(quality)) != "" {
		return false
	}
	if ceilingBps > 0 && sourceBitrateBps > ceilingBps {
		return false
	}
	return true
}

// NoBurnedSubtitle is the wire value meaning "no subtitle is burned in".
const NoBurnedSubtitle = -1

// maxAudioRenditions caps how many audio tracks a session publishes.
//
// Each rendition is a cheap stereo AAC encode (~1% of a core once the JIT
// throttle settles), but every one of them also writes segments for the whole
// film, so an unbounded count would fill the session's temp dir on a remux
// carrying a dozen dub tracks.
const maxAudioRenditions = 8

// SelectAudioRenditions picks which source audio tracks a session will carry,
// in source order, always including the one the client asked for.
func SelectAudioRenditions(probe *ProbeResult, requested int) []int {
	if probe == nil || len(probe.Audio) == 0 {
		return nil
	}
	total := len(probe.Audio)
	if requested < 0 || requested >= total {
		requested = 0
	}

	if total <= maxAudioRenditions {
		out := make([]int, total)
		for i := range out {
			out[i] = i
		}
		return out
	}

	// Over the cap: keep source order, but guarantee the requested track is in.
	keep := make(map[int]bool, maxAudioRenditions)
	keep[requested] = true
	for i := 0; i < total && len(keep) < maxAudioRenditions; i++ {
		keep[i] = true
	}
	out := make([]int, 0, len(keep))
	for i := 0; i < total; i++ {
		if keep[i] {
			out = append(out, i)
		}
	}
	return out
}

// BuildFFmpegArgs constructs the FFmpeg command-line for an HLS transcode.
//
// Design (video + a SINGLE audio track — deliberately lean):
//   - One H.264 video rendition (8-bit yuv420p) — the only heavy work.
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
		segDur = 2
	}

	args := []string{"-hide_banner", "-loglevel", "error"}

	// Hardware-assisted DECODING when the host offers any (VAAPI, VideoToolbox,
	// NVDEC...). ffmpeg silently falls back to software when nothing is
	// available, so this is free. On CPU-only hosts the decode of a 4K HEVC
	// 10-bit source is the real time-to-first-segment bottleneck, not the encode.
	args = append(args, "-hwaccel", "auto")

	// Single keyframe-accurate input seek; on the input (before -i) so the HLS
	// timeline resets to ~0 at the requested start position.
	if opt.StartSeconds > 0 {
		args = append(args, "-ss", strconv.Itoa(opt.StartSeconds))
	}
	args = append(args, "-i", opt.InputPath)

	// --- Mapping: video + every published audio rendition ---
	// Text subtitles never come through here (-sn below): they are served out of
	// band as .vtt. Only a bitmap track can be present, painted into the picture.
	audioIdxs := opt.AudioTypedIndexes
	scale := buildScaleFilter(opt.Probe, preset)
	burnIdx := opt.BurnSubtitleTypedIndex
	burn := opt.BurnSubtitle && burnIdx >= 0

	if burn {
		// sub2video turns the bitmap subtitle stream into video frames that
		// overlay composites onto the picture. Scaling happens AFTER the overlay:
		// the subtitle bitmaps are authored against the source resolution, so
		// compositing first keeps them correctly positioned and sized.
		graph := fmt.Sprintf("[0:v:0][0:s:%d]overlay", burnIdx)
		if scale != "" {
			graph += "[ov];[ov]" + scale + "[vout]"
		} else {
			graph += "[vout]"
		}
		args = append(args, "-filter_complex", graph, "-map", "[vout]")
	} else {
		args = append(args, "-map", "0:v:0")
	}

	for _, idx := range audioIdxs {
		args = append(args, "-map", fmt.Sprintf("0:a:%d?", idx))
	}
	// -vf and -filter_complex are mutually exclusive on the same output.
	if !burn && scale != "" {
		args = append(args, "-vf", scale)
	}

	// --- Video: repackage or re-encode ---
	if opt.CopyVideo {
		// Nothing to configure. No filter (there is no resize by definition), no
		// encoder settings, and no keyframe layout to impose: with -c:v copy the
		// muxer can only cut segments where the source already has a keyframe, so
		// -g / -force_key_frames would be silently ignored. Segment length
		// therefore follows the file's own GOP, which the indexer measures into
		// medias.gop_seconds.
		args = append(args, "-c:v", "copy")
		return append(args, audioAndMuxerArgs(opt, preset, audioIdxs, segDur)...)
	}

	// Force 8-bit 4:2:0 so 10-bit HEVC sources don't yield a "High 10" H.264
	// stream most clients can't decode.
	args = append(args,
		"-c:v", "libx264",
		"-preset", encoderPresetFor(preset),
		"-pix_fmt", "yuv420p",
		"-profile:v", "high",
		"-level", "4.1",
		"-crf", "23",
		"-b:v", "0",
		"-maxrate", preset.VideoBitrate,
		"-bufsize", doubleBitrate(preset.VideoBitrate),
		"-threads", strconv.Itoa(maxEncoderThreads),
	)

	// --- Keyframe layout ---
	// GOP is derived from the SOURCE frame rate: a fixed segDur*24 gives a 60fps
	// source a 1.6s GOP, spending bitrate on keyframes nobody needs.
	// sc_threshold=0 stops scene cuts from inserting extra IDRs that would
	// desynchronise the segment boundaries.
	gop := gopSize(opt.Probe, segDur)
	args = append(args,
		"-g", strconv.Itoa(gop),
		"-keyint_min", strconv.Itoa(gop),
		"-sc_threshold", "0",
		"-force_key_frames", fmt.Sprintf("expr:gte(t,n_forced*%d)", segDur),
	)

	return append(args, audioAndMuxerArgs(opt, preset, audioIdxs, segDur)...)
}

// audioAndMuxerArgs builds everything downstream of the video decision: the
// audio renditions and the HLS muxer. Both paths — re-encoded picture and
// copied picture — share it verbatim, which is what keeps the copy path from
// drifting away from the one that has been in production.
func audioAndMuxerArgs(opt TranscodeOptions, preset qualityPreset, audioIdxs []int, segDur int) []string {
	var args []string

	// --- Audio ---
	// Stereo AAC is what every client can decode. A track that is already exactly
	// that gets remuxed instead of re-encoded, decided per rendition.
	for i, idx := range audioIdxs {
		if canCopyAudio(opt.Probe, idx) {
			args = append(args, fmt.Sprintf("-c:a:%d", i), "copy")
			continue
		}
		args = append(args,
			fmt.Sprintf("-c:a:%d", i), "aac",
			fmt.Sprintf("-b:a:%d", i), preset.AudioBitrate,
			fmt.Sprintf("-ac:a:%d", i), "2",
		)
	}
	args = append(args, "-sn", "-max_muxing_queue_size", "1024")

	// One muxed variant (video + audio). The master playlist + stream_0.* naming
	// is preserved so the client and the segment-throttling logic are unchanged.
	//
	// hls_playlist_type=event marks the playlist append-only: without it players
	// treat a growing playlist as LIVE, which constrains backwards seeking and
	// forces continuous playlist refetches.
	args = append(args,
		"-f", "hls",
		"-hls_time", strconv.Itoa(segDur),
		"-hls_list_size", "0",
		"-hls_playlist_type", "event",
		"-hls_flags", "independent_segments+temp_file",
		"-master_pl_name", "master.m3u8",
		"-var_stream_map", buildVarStreamMap(opt.Probe, audioIdxs),
		"-hls_segment_filename", opt.TmpDir+"/stream_%v_%03d.ts",
		opt.TmpDir+"/stream_%v.m3u8",
	)

	return args
}

// buildVarStreamMap lays out one video variant plus an audio rendition group.
//
// Publishing every audio track as a rendition of a single group is what makes
// language switching instant: the player swaps group member without the server
// rebuilding anything. The video variant stays alone in its own playlist, so
// stream_0_*.ts remains the video segment series the JIT throttle counts.
func buildVarStreamMap(probe *ProbeResult, audioIdxs []int) string {
	if len(audioIdxs) == 0 {
		return "v:0"
	}

	parts := make([]string, 0, len(audioIdxs)+1)
	parts = append(parts, "v:0,agroup:aud")
	for i, srcIdx := range audioIdxs {
		part := fmt.Sprintf("a:%d,agroup:aud", i)
		if lang := audioLanguage(probe, srcIdx); lang != "" {
			part += ",language:" + lang
		}
		parts = append(parts, part)
	}
	return strings.Join(parts, " ")
}

// audioLanguage returns the source language tag of a typed audio index, sanitised
// for use as an HLS attribute value.
func audioLanguage(probe *ProbeResult, typedIndex int) string {
	if probe == nil || typedIndex < 0 || typedIndex >= len(probe.Audio) {
		return ""
	}
	lang := strings.TrimSpace(probe.Audio[typedIndex].Language)
	// The value lands unquoted in -var_stream_map, whose grammar is
	// space/comma-separated; anything else would corrupt the whole map.
	for _, r := range lang {
		if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && r != '-' {
			return ""
		}
	}
	return lang
}

// buildScaleFilter returns the -vf value, or "" when no scaling is needed.
//
// Two things the naive `scale=W:H` got wrong:
//   - it UPSCALED a smaller source to the requested rendition, burning CPU and
//     bitrate on invented pixels;
//   - forcing both dimensions makes ffmpeg preserve display aspect through a
//     non-square SAR instead of just fitting the frame.
//
// force_original_aspect_ratio=decrease fits inside the box and keeps square
// pixels; when the source already fits, scaling is skipped entirely.
func buildScaleFilter(probe *ProbeResult, preset qualityPreset) string {
	if probe != nil && probe.Video != nil {
		w, h := probe.Video.Width, probe.Video.Height
		if w > 0 && h > 0 && w <= preset.W && h <= preset.H {
			return "" // source already fits — no resampling at all
		}
	}
	return fmt.Sprintf(
		"scale=w=%d:h=%d:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bilinear",
		preset.W, preset.H,
	)
}

// gopSize returns the keyframe interval in frames for one segment duration.
func gopSize(probe *ProbeResult, segDur int) int {
	fps := 24.0
	if probe != nil && probe.Video != nil && probe.Video.FrameRate > 0 {
		fps = probe.Video.FrameRate
	}
	// Guard against absurd probe values (VFR containers report 1000fps).
	if fps < 1 || fps > 120 {
		fps = 24
	}
	gop := int(fps * float64(segDur))
	if gop < 1 {
		gop = 1
	}
	return gop
}

// canCopyAudio reports whether the selected source track is already a stereo
// AAC stream that can be remuxed as-is into the HLS segments.
func canCopyAudio(probe *ProbeResult, typedIndex int) bool {
	if probe == nil || typedIndex < 0 || typedIndex >= len(probe.Audio) {
		return false
	}
	a := probe.Audio[typedIndex]
	return strings.EqualFold(a.Codec, "aac") && a.Channels > 0 && a.Channels <= 2
}

// doubleBitrate turns "8M"/"8000k" into a ~2× VBV buffer size string.
func doubleBitrate(rate string) string {
	if len(rate) < 2 {
		return rate
	}
	unit := rate[len(rate)-1]
	numStr := rate[:len(rate)-1]
	n, err := strconv.Atoi(numStr)
	if err != nil {
		return rate
	}
	return fmt.Sprintf("%d%c", n*2, unit)
}

// EstimateBandwidth returns a rough bandwidth estimate (bits/s) for a quality.
// Derived from the preset's own VBV ceiling so the advertised figure and the
// stream the encoder actually produces can no longer drift apart.
func EstimateBandwidth(quality string) int {
	p := presetFor(quality)
	video := parseBitrate(p.VideoBitrate)
	audio := parseBitrate(p.AudioBitrate)
	if video == 0 {
		return 2800000
	}
	return video + audio
}

// parseBitrate turns "3500k" / "6M" into bits per second.
func parseBitrate(rate string) int {
	if rate == "" {
		return 0
	}
	mult := 1
	numStr := rate
	switch rate[len(rate)-1] {
	case 'k', 'K':
		mult, numStr = 1000, rate[:len(rate)-1]
	case 'm', 'M':
		mult, numStr = 1000000, rate[:len(rate)-1]
	}
	n, err := strconv.Atoi(numStr)
	if err != nil {
		return 0
	}
	return n * mult
}
