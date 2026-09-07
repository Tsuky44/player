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
	// Video is what happens to the picture: repackaged, or re-encoded and
	// possibly tone mapped. Produced by PlanVideo, which enforces every
	// condition that makes a copy safe.
	//
	// The expensive half of a transcode is the video: decode every frame, encode
	// every frame. When the client can already decode what the file holds, none
	// of that is necessary — the compressed bytes only need to move from one
	// container into another, which costs I/O and nothing else. Measured against
	// the encoding path it is roughly fifty times cheaper, and the picture comes
	// out bit-identical to the source instead of a generation down.
	Video VideoPlan
	// Caps is what the client declared it can decode. The zero value means a
	// client that declared nothing, which is treated as the browser this server
	// was originally written for — see LegacyCapabilities.
	Caps Capabilities
}

// caps resolves the client declaration, defaulting to the legacy one.
//
// A zero Capabilities is not a client that can decode nothing — it is a caller
// that did not fill the field in, which every existing test and every
// already-installed app build is. Treating it as the legacy browser is what
// makes this change invisible to them.
func (o TranscodeOptions) caps() Capabilities {
	if o.Caps.VideoCodecs == nil || o.Caps.AudioCodecs == nil {
		return LegacyCapabilities()
	}
	return o.Caps
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
	burnIdx := opt.BurnSubtitleTypedIndex
	burn := opt.BurnSubtitle && burnIdx >= 0
	chain := videoFilterChain(opt, preset)

	if burn {
		// sub2video turns the bitmap subtitle stream into video frames that
		// overlay composites onto the picture. Everything else happens AFTER the
		// overlay: the subtitle bitmaps are authored against the source
		// resolution, so compositing first keeps them correctly positioned and
		// sized.
		graph := fmt.Sprintf("[0:v:0][0:s:%d]overlay", burnIdx)
		if chain != "" {
			graph += "[ov];[ov]" + chain + "[vout]"
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
	if !burn && chain != "" {
		args = append(args, "-vf", chain)
	}

	// --- Video: repackage or re-encode ---
	if opt.Video.Copy {
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
		"-level", h264LevelFor(preset, opt.Probe),
		"-crf", "23",
		"-b:v", "0",
		"-maxrate", preset.VideoBitrate,
		"-bufsize", doubleBitrate(preset.VideoBitrate),
		"-threads", strconv.Itoa(maxEncoderThreads),
	)

	// A tone-mapped picture is BT.709 now, and it has to say so. The tags are
	// not decoration: a player handed untagged frames from an HDR source falls
	// back to the container's own colour metadata, which still says BT.2020 PQ —
	// and re-applies a conversion to a picture that has already had one.
	if opt.Video.Tonemap {
		args = append(args,
			"-colorspace", "bt709",
			"-color_primaries", "bt709",
			"-color_trc", "bt709",
		)
	}

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
	// One decision per rendition, taken by PlanAudio: remux what the client can
	// already take, keep the channels when it can carry them, and fold to stereo
	// only when there is nothing else left.
	for i, idx := range audioIdxs {
		plan := PlanAudio(opt.Probe, idx, opt.caps(), preset)
		if plan.Copy {
			args = append(args, fmt.Sprintf("-c:a:%d", i), "copy")
			continue
		}
		args = append(args,
			fmt.Sprintf("-c:a:%d", i), plan.Codec,
			fmt.Sprintf("-b:a:%d", i), plan.Bitrate,
			fmt.Sprintf("-ac:a:%d", i), strconv.Itoa(plan.Channels),
		)
		if plan.Downmix {
			args = append(args, fmt.Sprintf("-filter:a:%d", i), stereoDownmixFilter())
		}
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
	)

	// fMP4 rather than MPEG-TS is what lets the copy path exist at all for
	// anything but H.264. MPEG-TS has no stream type for VP9 or AV1 and no
	// standard one for FLAC or Opus, so `-c copy` of those makes FFmpeg refuse
	// to write a header and exit before its first segment. It is also the only
	// segment format that carries HDR metadata through a copy intact.
	//
	// Each variant gets its own initialisation segment, which the child playlist
	// references with EXT-X-MAP — so the handler has to serve init_%v.mp4 and
	// .m4s alongside the playlists.
	caps := opt.caps()
	if caps.Container == ContainerFMP4 {
		args = append(args,
			"-hls_segment_type", "fmp4",
			"-hls_fmp4_init_filename", "init_%v.mp4",
		)
	}

	args = append(args,
		// Required for -var_stream_map to lay out a rendition group, but the file
		// it produces is never served: the handler answers master.m3u8 from
		// BuildMasterPlaylist instead, for the reasons documented there.
		"-master_pl_name", "master.m3u8",
		"-var_stream_map", buildVarStreamMap(opt.Probe, audioIdxs),
		"-hls_segment_filename", opt.TmpDir+"/stream_%v_%03d"+caps.Container.SegmentExt(),
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

// videoFilterChain is everything the picture goes through on the encoding path,
// or "" when it needs nothing.
//
// Order is deliberate. Scaling comes first because every filter after it then
// runs on fewer pixels, and tone mapping is by far the most expensive thing
// here — on the CPU-only host that difference is the margin between keeping up
// with playback and not. Scaling in PQ space before the transfer is undone is
// a known, universally accepted approximation; doing it the other way round is
// marginally more correct and measurably too slow.
func videoFilterChain(opt TranscodeOptions, preset qualityPreset) string {
	if opt.Video.Copy {
		return "" // copied frames are never filtered, by definition
	}
	var parts []string
	if scale := buildScaleFilter(opt.Probe, preset); scale != "" {
		parts = append(parts, scale)
	}
	if opt.Video.Tonemap {
		if tm := hdrToSDRFilter(); tm != "" {
			parts = append(parts, tm)
		}
	}
	return strings.Join(parts, ",")
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

// outputResolution reports the frame size the session will actually publish,
// for the master playlist's RESOLUTION attribute. ok is false when there is no
// picture to describe.
//
// It mirrors buildScaleFilter: a source that already fits keeps its own size
// (nothing is upscaled), and anything larger is fitted inside the preset's box.
// Being a pixel or two away from what the scaler rounds to is harmless — players
// use RESOLUTION to choose between variants and to size their surface, not to
// decode — but claiming a 4K rendition on a 720p stream would misinform both.
func outputResolution(probe *ProbeResult, preset qualityPreset) (int, int, bool) {
	if probe == nil || probe.Video == nil {
		return 0, 0, false
	}
	w, h := probe.Video.Width, probe.Video.Height
	if w <= 0 || h <= 0 {
		return 0, 0, false
	}
	if buildScaleFilter(probe, preset) == "" {
		return w, h, true
	}

	// force_original_aspect_ratio=decrease: fit inside the box on whichever axis
	// binds first, keeping square pixels. force_divisible_by=2 then rounds each
	// side down to an even number, which is what yuv420p requires.
	scale := float64(preset.W) / float64(w)
	if vScale := float64(preset.H) / float64(h); vScale < scale {
		scale = vScale
	}
	ow := int(float64(w)*scale+0.5) &^ 1
	oh := int(float64(h)*scale+0.5) &^ 1
	if ow < 2 {
		ow = 2
	}
	if oh < 2 {
		oh = 2
	}
	return ow, oh, true
}

// sourceFrameRate returns the source frame rate in fps, guarding against the
// absurd values VFR containers report (Matroska happily claims 1000fps).
func sourceFrameRate(probe *ProbeResult) float64 {
	fps := 24.0
	if probe != nil && probe.Video != nil && probe.Video.FrameRate > 0 {
		fps = probe.Video.FrameRate
	}
	if fps < 1 || fps > 120 {
		fps = 24
	}
	return fps
}

// gopSize returns the keyframe interval in frames for one segment duration.
func gopSize(probe *ProbeResult, segDur int) int {
	gop := int(sourceFrameRate(probe) * float64(segDur))
	if gop < 1 {
		gop = 1
	}
	return gop
}

// h264LevelFor returns the H.264 level to declare for a rendition.
//
// The level is not decoration: libx264 writes it into the SPS, and it is what a
// browser's *hardware* decoder consults before accepting the stream. The fixed
// "4.1" this used to pass caps out at 1080p30 — it under-declares every 2160p
// rendition and every 1080p50/60 one, and a decoder that refuses on that basis
// refuses the way browser video always does: segments load, audio plays, the
// picture never arrives.
//
// Only ever raised above 4.1, never lowered. A level is also a VBV constraint
// the encoder must respect, and the presets' ceilings are chosen against the
// viewer's link, not against a profile table — so a 720p tier stays at 4.1
// rather than dropping to the 3.1 its pixel count would allow.
func h264LevelFor(preset qualityPreset, probe *ProbeResult) string {
	// 4.1/5.1 are the ≤30fps tiers of their frame size; past that the macroblock
	// rate needs the next one up. The threshold sits at 33 so 29.97 and 30 land
	// below it and 50/59.94/60 above.
	highFrameRate := sourceFrameRate(probe) > 33

	switch {
	case preset.H > 1080:
		if highFrameRate {
			return "5.2"
		}
		return "5.1"
	case preset.H > 720:
		if highFrameRate {
			return "4.2"
		}
		return "4.1"
	default:
		return "4.1"
	}
}

// stereoDownmixFilter is the -filter:a value that folds a surround track into
// the two channels every client can play, without burying the dialogue. Empty
// for a track that is already stereo or mono, which needs no help.
//
// The `-ac 2` above is enough to *produce* stereo, and what it produces is the
// standard downmix: the front pair at unity and the centre at 0.707. (The
// normalisation that divides a downmix by the sum of its own coefficients only
// applies when the result lands in an integer sample format; the AAC encoder
// works in float, so nothing here is attenuated.) A plain -3 dB, on the one
// channel that carries the dialogue and on nothing else, is the whole of the
// "the voices are buried" complaint — and carrying the centre at 1.0 like the
// fronts is the whole of the fix: +3 dB on speech, the rest of the mix exactly
// where the film put it. The surrounds keep their standard 0.707 and the LFE,
// dropped entirely by default, comes back low enough to add weight without
// becoming the mix.
//
// These are the three numbers the client hands mpv for a Direct Play file
// (`dialogueForwardMixLevels`), against the same swresample rematrix, so a
// title sounds the same whether it was transcoded on the way out or not.
//
// It is one `aresample` and nothing else on purpose. The obvious alternative —
// a `pan` graph with explicit coefficients — has to name channels by index,
// which is only correct once you know the layout, and it needs `pan`,
// `aformat` and `alimiter` to all exist in the FFmpeg it lands on. Mix levels
// need none of that: swresample applies them to whatever layout arrives, and a
// stereo track passes through untouched. The output layout is deliberately not
// named here either — `-ac:a:N 2` already supplies it, and the option that
// spells it has been renamed between FFmpeg releases.
func stereoDownmixFilter() string {
	return "aresample=" +
		"center_mix_level=1.0:" +
		"surround_mix_level=0.7:" +
		"lfe_mix_level=0.3"
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
