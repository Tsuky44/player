package streaming

import (
	"strings"
	"testing"
)

func argValue(args []string, flag string) (string, bool) {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1], true
		}
	}
	return "", false
}

func hasArg(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func probeWith(w, h int, fps float64, audio ...AudioStreamInfo) *ProbeResult {
	return &ProbeResult{
		Video: &VideoStreamInfo{Width: w, Height: h, FrameRate: fps},
		Audio: audio,
	}
}

func TestBuildScaleFilter_SkipsUpscale(t *testing.T) {
	// A 1280x536 scope source asked for 1080p must not be blown up.
	if got := buildScaleFilter(probeWith(1280, 536, 24), presetFor("1080p")); got != "" {
		t.Fatalf("expected no scaling for a source smaller than the preset, got %q", got)
	}
	// Exactly at the preset size: still nothing to do.
	if got := buildScaleFilter(probeWith(1280, 720, 24), presetFor("720p")); got != "" {
		t.Fatalf("expected no scaling when the source already fits, got %q", got)
	}
}

func TestBuildScaleFilter_DownscalePreservesAspect(t *testing.T) {
	got := buildScaleFilter(probeWith(3840, 2160, 24), presetFor("720p"))
	if got == "" {
		t.Fatal("expected a scale filter when downscaling 4K to 720p")
	}
	if !strings.Contains(got, "force_original_aspect_ratio=decrease") {
		t.Errorf("scale filter must fit inside the box with square pixels: %q", got)
	}
	if !strings.Contains(got, "force_divisible_by=2") {
		t.Errorf("scale filter must keep even dimensions for yuv420p: %q", got)
	}
}

func TestBuildScaleFilter_UnknownProbeStillScales(t *testing.T) {
	// No probe: we cannot prove the source fits, so scaling must stay on.
	if got := buildScaleFilter(nil, presetFor("720p")); got == "" {
		t.Fatal("expected a scale filter when the source size is unknown")
	}
}

func TestGopSize_FollowsSourceFrameRate(t *testing.T) {
	cases := []struct {
		name   string
		fps    float64
		segDur int
		want   int
	}{
		{"24fps/2s", 24, 2, 48},
		{"60fps/2s", 60, 2, 120},
		{"23.976fps/2s", 24000.0 / 1001.0, 2, 47},
		{"unknown falls back to 24", 0, 2, 48},
		{"absurd VFR value falls back to 24", 1000, 2, 48},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := gopSize(probeWith(1920, 1080, tc.fps), tc.segDur); got != tc.want {
				t.Errorf("gopSize = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestPlanAudio_LegacyClientStillGetsStereoAAC(t *testing.T) {
	stereoAAC := AudioStreamInfo{Codec: "aac", Channels: 2}
	surroundAAC := AudioStreamInfo{Codec: "aac", Channels: 6}
	dts := AudioStreamInfo{Codec: "dts", Channels: 6}
	legacy := LegacyCapabilities()
	preset := presetFor("720p")

	if p := PlanAudio(probeWith(1920, 1080, 24, stereoAAC), 0, legacy, preset); !p.Copy {
		t.Error("stereo AAC is exactly what the legacy client takes untouched")
	}
	// 5.1 AAC is still AAC, but the legacy client has nowhere to put six
	// channels — it has to be folded, and folding means re-encoding.
	p := PlanAudio(probeWith(1920, 1080, 24, surroundAAC), 0, legacy, preset)
	if p.Copy || p.Channels != 2 || !p.Downmix {
		t.Errorf("5.1 AAC to a stereo client = %+v, want a 2-channel downmix", p)
	}
	p = PlanAudio(probeWith(1920, 1080, 24, dts), 0, legacy, preset)
	if p.Copy || p.Codec != "aac" || p.Channels != 2 {
		t.Errorf("DTS to a stereo client = %+v, want stereo AAC", p)
	}
	// An index the probe does not have must not panic, and must not claim a copy.
	if p := PlanAudio(probeWith(1920, 1080, 24, stereoAAC), 5, legacy, preset); p.Copy {
		t.Error("an out-of-range track cannot be copied")
	}
	if p := PlanAudio(nil, 0, legacy, preset); p.Copy {
		t.Error("no probe means no copy")
	}
}

// surroundCaps is a living-room client: fMP4 segments, the Dolby codecs, and an
// amplifier behind it.
func surroundCaps() Capabilities {
	return Capabilities{
		Container:        ContainerFMP4,
		VideoCodecs:      map[string]bool{"h264": true, "hevc": true},
		AudioCodecs:      map[string]bool{"aac": true, "ac3": true, "eac3": true},
		MaxAudioChannels: 8,
		MaxVideoBitDepth: 10,
		HDR:              true,
	}
}

func TestPlanAudio_SurroundSurvivesWhenTheClientCanCarryIt(t *testing.T) {
	preset := presetFor("1080p")

	// Dolby Digital Plus is remuxed untouched — which is the only way Atmos,
	// which rides inside it as JOC, ever reaches the amplifier.
	atmos := AudioStreamInfo{
		Codec: "eac3", Channels: 6,
		Profile: "Dolby Digital Plus + Dolby Atmos",
	}
	p := PlanAudio(probeWith(1920, 1080, 24, atmos), 0, surroundCaps(), preset)
	if !p.Copy || p.Channels != 6 {
		t.Errorf("E-AC-3 5.1 to a surround client = %+v, want an untouched copy", p)
	}

	// DTS has no home in fMP4, so it is re-encoded — but to surround, not to
	// stereo, because the client said it can take six channels.
	dts := AudioStreamInfo{Codec: "dts", Channels: 6, Profile: "DTS-HD MA"}
	p = PlanAudio(probeWith(1920, 1080, 24, dts), 0, surroundCaps(), preset)
	if p.Copy {
		t.Fatal("DTS cannot be muxed into fMP4 and must not be copied")
	}
	if p.Codec != "eac3" || p.Channels != 6 || p.Downmix {
		t.Errorf("DTS 5.1 to a surround client = %+v, want 6-channel E-AC-3", p)
	}

	// 7.1 past what the AC-3 encoders accept folds to 5.1, not to stereo.
	eight := AudioStreamInfo{Codec: "dts", Channels: 8}
	p = PlanAudio(probeWith(1920, 1080, 24, eight), 0, surroundCaps(), preset)
	if p.Channels != maxAC3Channels {
		t.Errorf("7.1 DTS = %d channels, want %d", p.Channels, maxAC3Channels)
	}
}

func TestPlanAudio_ChannelCeilingIsTheClientOutput(t *testing.T) {
	// Same file, same codecs, a client wired to nothing but its own speakers.
	caps := surroundCaps()
	caps.MaxAudioChannels = 2
	eac3 := AudioStreamInfo{Codec: "eac3", Channels: 6}

	p := PlanAudio(probeWith(1920, 1080, 24, eac3), 0, caps, presetFor("1080p"))
	if p.Copy {
		t.Fatal("a stereo output cannot be handed a 5.1 stream")
	}
	if p.Channels != 2 || !p.Downmix {
		t.Errorf("= %+v, want a 2-channel downmix", p)
	}
}

func TestBuildFFmpegArgs_BitrateIsAlwaysCapped(t *testing.T) {
	// An uncapped CRF let a "2.8 Mbps" 720p rendition burst past 15 Mbps on a
	// detailed scene, which is exactly what the client cannot absorb.
	for _, q := range []string{"360p", "480p", "720p", "1080p", "2160p"} {
		args := BuildFFmpegArgs(TranscodeOptions{
			InputPath:       "/tmp/in.mkv",
			Quality:         q,
			TmpDir:          "/tmp/out",
			Probe:           probeWith(3840, 2160, 24),
			SegmentDuration: 2,
		})
		maxrate, ok := argValue(args, "-maxrate")
		if !ok || maxrate == "" {
			t.Errorf("quality %s: missing -maxrate ceiling", q)
		}
		if bufsize, ok := argValue(args, "-bufsize"); !ok || bufsize == "" {
			t.Errorf("quality %s: missing -bufsize", q)
		}
		if maxrate != presetFor(q).VideoBitrate {
			t.Errorf("quality %s: -maxrate %s does not match preset %s",
				q, maxrate, presetFor(q).VideoBitrate)
		}
	}
}

func TestBuildFFmpegArgs_StreamShape(t *testing.T) {
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:         "/tmp/in.mkv",
		Quality:           "720p",
		TmpDir:            "/tmp/out",
		Probe:             probeWith(1920, 1080, 24),
		SegmentDuration:   2,
		AudioTypedIndexes: []int{0, 1},
	})

	if !hasArg(args, "-sn") {
		t.Error("subtitles must stay out of band")
	}
	if v, _ := argValue(args, "-map"); v != "0:v:0" {
		t.Errorf("first map should be the video stream, got %q", v)
	}
	if !hasArg(args, "0:a:1?") {
		t.Error("every published audio track must be mapped by typed index")
	}
	if v, _ := argValue(args, "-hls_playlist_type"); v != "event" {
		t.Errorf("playlist must be append-only (event), got %q", v)
	}
	if v, _ := argValue(args, "-hwaccel"); v != "auto" {
		t.Errorf("hardware decode should be attempted, got %q", v)
	}
	if v, _ := argValue(args, "-preset"); v == "ultrafast" {
		t.Error("ultrafast emits ~2.4x the bitrate for marginal time savings")
	}
	if v, _ := argValue(args, "-sc_threshold"); v != "0" {
		t.Error("scene-cut IDRs would desynchronise segment boundaries")
	}
}

func audioProbe(langs ...string) *ProbeResult {
	p := &ProbeResult{Video: &VideoStreamInfo{Width: 1920, Height: 1080, FrameRate: 24}}
	for _, l := range langs {
		p.Audio = append(p.Audio, AudioStreamInfo{Codec: "dts", Channels: 6, Language: l})
	}
	return p
}

func TestSelectAudioRenditions(t *testing.T) {
	t.Run("all tracks below the cap, in source order", func(t *testing.T) {
		got := SelectAudioRenditions(audioProbe("fra", "eng", "jpn"), 1)
		want := []int{0, 1, 2}
		if len(got) != len(want) {
			t.Fatalf("got %v, want %v", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("got %v, want %v", got, want)
			}
		}
	})

	t.Run("over the cap keeps the requested track", func(t *testing.T) {
		langs := make([]string, maxAudioRenditions+4)
		for i := range langs {
			langs[i] = "und"
		}
		requested := maxAudioRenditions + 2 // beyond the first N
		got := SelectAudioRenditions(audioProbe(langs...), requested)

		if len(got) != maxAudioRenditions {
			t.Fatalf("expected %d renditions, got %d", maxAudioRenditions, len(got))
		}
		found := false
		for _, v := range got {
			if v == requested {
				found = true
			}
		}
		if !found {
			t.Errorf("requested track %d dropped from %v — it would be unplayable",
				requested, got)
		}
		for i := 1; i < len(got); i++ {
			if got[i] <= got[i-1] {
				t.Fatalf("renditions must stay in source order: %v", got)
			}
		}
	})

	t.Run("no audio yields no renditions", func(t *testing.T) {
		if got := SelectAudioRenditions(audioProbe(), 0); len(got) != 0 {
			t.Errorf("got %v, want empty", got)
		}
		if got := SelectAudioRenditions(nil, 0); len(got) != 0 {
			t.Errorf("got %v, want empty", got)
		}
	})

	t.Run("out-of-range request falls back to the first track", func(t *testing.T) {
		if got := SelectAudioRenditions(audioProbe("fra"), 99); len(got) != 1 || got[0] != 0 {
			t.Errorf("got %v, want [0]", got)
		}
	})
}

func TestBuildVarStreamMap(t *testing.T) {
	t.Run("one group holding every rendition", func(t *testing.T) {
		got := buildVarStreamMap(audioProbe("fra", "eng"), []int{0, 1})
		want := "v:0,agroup:aud a:0,agroup:aud,language:fra a:1,agroup:aud,language:eng"
		if got != want {
			t.Errorf("got  %q\nwant %q", got, want)
		}
	})

	t.Run("video only when the file has no audio", func(t *testing.T) {
		if got := buildVarStreamMap(audioProbe(), nil); got != "v:0" {
			t.Errorf("got %q, want v:0", got)
		}
	})

	t.Run("a hostile language tag cannot corrupt the map", func(t *testing.T) {
		// The value is interpolated unquoted into a space/comma separated
		// grammar, so anything outside [A-Za-z-] must be dropped entirely.
		got := buildVarStreamMap(audioProbe("fr,agroup:evil name:x"), []int{0})
		if strings.Contains(got, "evil") {
			t.Fatalf("language tag leaked into the map: %q", got)
		}
		if got != "v:0,agroup:aud a:0,agroup:aud" {
			t.Errorf("got %q", got)
		}
	})
}

func TestBuildFFmpegArgs_PerRenditionAudioCodec(t *testing.T) {
	probe := &ProbeResult{
		Video: &VideoStreamInfo{Width: 1280, Height: 720, FrameRate: 24},
		Audio: []AudioStreamInfo{
			{Codec: "aac", Channels: 2}, // already deliverable -> copy
			{Codec: "dts", Channels: 6}, // must be downmixed -> aac
			{Codec: "aac", Channels: 6}, // 5.1 AAC still needs a downmix
		},
	}
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "720p", TmpDir: "/tmp/out",
		Probe: probe, SegmentDuration: 2, AudioTypedIndexes: []int{0, 1, 2},
	})

	if v, ok := argValue(args, "-c:a:0"); !ok || v != "copy" {
		t.Errorf("stereo AAC should be remuxed, got %q", v)
	}
	if v, ok := argValue(args, "-c:a:1"); !ok || v != "aac" {
		t.Errorf("DTS should be transcoded, got %q", v)
	}
	if v, ok := argValue(args, "-c:a:2"); !ok || v != "aac" {
		t.Errorf("5.1 AAC should be downmixed, got %q", v)
	}
	if v, ok := argValue(args, "-ac:a:1"); !ok || v != "2" {
		t.Errorf("transcoded audio should be stereo, got %q", v)
	}
	// Every published track must be mapped, or the rendition group is short one
	// member and the client's audio map points at nothing.
	for _, want := range []string{"0:a:0?", "0:a:1?", "0:a:2?"} {
		if !hasArg(args, want) {
			t.Errorf("missing map %s", want)
		}
	}
}

func TestBuildFFmpegArgs_4KUsesAFasterPresetThanEverythingElse(t *testing.T) {
	// A fresh session starts with zero buffer, and 4K is 4x the pixels of 1080p:
	// "veryfast" measured at only 1.30x real-time on 4K (vs 3.55x for
	// ultrafast), which on a slower CPU-only host plus real HEVC decode
	// overhead can slip below 1x — an encoder that can never be faster than
	// the video it is producing can never fill the buffer it starts without.
	got2160, _ := argValue(BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "2160p", TmpDir: "/tmp/out",
		Probe: probeWith(3840, 2160, 24), SegmentDuration: 2,
	}), "-preset")
	if got2160 != "ultrafast" {
		t.Errorf("2160p preset = %q, want ultrafast", got2160)
	}

	// Every other tier keeps the bitrate-efficient default — this is a targeted
	// override, not a global regression to a worse-quality preset.
	for _, q := range []string{"360p", "480p", "720p", "1080p"} {
		got, _ := argValue(BuildFFmpegArgs(TranscodeOptions{
			InputPath: "/tmp/in.mkv", Quality: q, TmpDir: "/tmp/out",
			Probe: probeWith(3840, 2160, 24), SegmentDuration: 2,
		}), "-preset")
		if got != "veryfast" {
			t.Errorf("quality %s: preset = %q, want veryfast (unaffected by the 2160p override)", q, got)
		}
	}
}

func TestBuildFFmpegArgs_BurnInIsOptOut(t *testing.T) {
	// 0 is a valid stream index, so a zero-valued TranscodeOptions must NOT be
	// read as "burn in 0:s:0" — that would silently paint subtitles onto every
	// stream whose options were built without thinking about it.
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "720p", TmpDir: "/tmp/out",
		Probe: probeWith(1920, 1080, 24), SegmentDuration: 2,
	})
	if hasArg(args, "-filter_complex") {
		t.Error("no burn-in was requested, yet a filter graph was built")
	}
	if v, _ := argValue(args, "-map"); v != "0:v:0" {
		t.Errorf("video should be mapped directly, got %q", v)
	}
}

func TestBuildFFmpegArgs_BurnInCompositesBeforeScaling(t *testing.T) {
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "720p", TmpDir: "/tmp/out",
		Probe:           probeWith(1920, 1080, 24),
		SegmentDuration: 2, AudioTypedIndexes: []int{0},
		BurnSubtitle: true, BurnSubtitleTypedIndex: 2,
	})

	graph, ok := argValue(args, "-filter_complex")
	if !ok {
		t.Fatal("burn-in requested but no filter graph was built")
	}
	if !strings.Contains(graph, "[0:v:0][0:s:2]overlay") {
		t.Errorf("graph must overlay the requested bitmap stream: %q", graph)
	}
	// Subtitle bitmaps are authored against the source resolution, so they have
	// to be composited BEFORE the downscale or they land at the wrong size.
	overlayAt := strings.Index(graph, "overlay")
	scaleAt := strings.Index(graph, "scale=")
	if scaleAt < 0 {
		t.Fatalf("expected a scale stage for 1080p->720p: %q", graph)
	}
	if overlayAt > scaleAt {
		t.Errorf("overlay must come before scale: %q", graph)
	}
	if v, _ := argValue(args, "-map"); v != "[vout]" {
		t.Errorf("video must be mapped from the filter output, got %q", v)
	}
	// -vf and -filter_complex cannot both drive the same output.
	if hasArg(args, "-vf") {
		t.Error("-vf must not be combined with -filter_complex")
	}
}

func TestBuildFFmpegArgs_BurnInWithoutScaling(t *testing.T) {
	// Source already fits the preset: the graph is overlay only, and must still
	// terminate in the [vout] label the mapping refers to.
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "1080p", TmpDir: "/tmp/out",
		Probe:           probeWith(1920, 1080, 24),
		SegmentDuration: 2,
		BurnSubtitle:    true, BurnSubtitleTypedIndex: 0,
	})
	graph, _ := argValue(args, "-filter_complex")
	if graph != "[0:v:0][0:s:0]overlay[vout]" {
		t.Errorf("got %q", graph)
	}
}

func TestBuildFFmpegArgs_SeekIsAnInputOption(t *testing.T) {
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath:       "/tmp/in.mkv",
		Quality:         "720p",
		StartSeconds:    600,
		TmpDir:          "/tmp/out",
		Probe:           probeWith(1920, 1080, 24),
		SegmentDuration: 2,
	})
	ssPos, iPos := -1, -1
	for i, a := range args {
		if a == "-ss" && ssPos == -1 {
			ssPos = i
		}
		if a == "-i" && iPos == -1 {
			iPos = i
		}
	}
	if ssPos == -1 {
		t.Fatal("missing -ss")
	}
	if ssPos > iPos {
		t.Error("-ss must precede -i so the HLS timeline restarts at the offset")
	}
}

func TestPlanVideo_OnlyCodecsThatFitInTheSegmentContainer(t *testing.T) {
	// MPEG-TS has no stream type for VP8/VP9/AV1: copying one makes FFmpeg refuse
	// to write a header and exit before its first segment, so /start times out and
	// the media never loads at all. The client declaring the codec does not change
	// that — the container is a separate veto.
	tsClient := LegacyCapabilities()
	tsClient.VideoCodecs = map[string]bool{
		"h264": true, "hevc": true, "vp8": true, "vp9": true, "av1": true,
	}
	for _, codec := range []string{"vp8", "vp9", "av1"} {
		probe := &ProbeResult{Video: &VideoStreamInfo{
			Width: 1920, Height: 1080, Codec: codec, PixFmt: "yuv420p",
		}}
		if PlanVideo(probe, "1080p", false, 5_000_000, 12_000_000, tsClient).Copy {
			t.Errorf("%s cannot be copied into MPEG-TS segments", codec)
		}
	}

	h264 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "h264", PixFmt: "yuv420p",
	}}
	if !PlanVideo(h264, "1080p", false, 5_000_000, 12_000_000, tsClient).Copy {
		t.Error("8-bit 4:2:0 H.264 at native resolution is the whole point of the copy path")
	}

	// The same VP9 file, to the same decoder, over fMP4 segments: now it copies.
	fmp4Client := tsClient
	fmp4Client.Container = ContainerFMP4
	vp9 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "vp9", PixFmt: "yuv420p",
	}}
	if !PlanVideo(vp9, "1080p", false, 5_000_000, 12_000_000, fmp4Client).Copy {
		t.Error("fMP4 segments are what let VP9 be repackaged instead of re-encoded")
	}
}

func TestPlanVideo_RejectsWhatTheClientCannotDecode(t *testing.T) {
	// 10-bit and 4:2:2 both fail silently in a browser: the segments append, the
	// audio plays, and the picture never appears. Neither may reach the copy path
	// for a client that declared 8-bit.
	for _, pixFmt := range []string{"yuv420p10le", "yuv422p", "yuvj422p", "yuv444p", "unknown", ""} {
		probe := &ProbeResult{Video: &VideoStreamInfo{
			Width: 1920, Height: 1080, Codec: "h264", PixFmt: pixFmt,
		}}
		if PlanVideo(probe, "1080p", false, 5_000_000, 12_000_000, LegacyCapabilities()).Copy {
			t.Errorf("pix_fmt %q must not be copied through to an 8-bit client", pixFmt)
		}
	}

	// A client that declared 10-bit takes Main 10 untouched — that is the single
	// most common file in a modern library, and it used to be re-encoded always.
	caps := surroundCaps()
	main10 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "hevc", PixFmt: "yuv420p10le", BitDepth: 10,
	}}
	if !PlanVideo(main10, "1080p", false, 5_000_000, 12_000_000, caps).Copy {
		t.Error("10-bit HEVC to a 10-bit client is a copy")
	}
	// 4:2:2 is still refused at any declared depth: no consumer decoder takes it.
	main422 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "hevc", PixFmt: "yuv422p10le", BitDepth: 10,
	}}
	if PlanVideo(main422, "1080p", false, 5_000_000, 12_000_000, caps).Copy {
		t.Error("4:2:2 must never be copied")
	}
}

func TestPlanVideo_HDRIsCopiedOrToneMappedButNeverPassedToAnSDRClient(t *testing.T) {
	hdr := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "hevc", PixFmt: "yuv420p10le",
		BitDepth: 10, ColorTransfer: "smpte2084", ColorPrimaries: "bt2020",
	}}
	if got := hdr.Video.HDRFormat(); got != "hdr10" {
		t.Fatalf("HDRFormat() = %q, want hdr10", got)
	}

	// An HDR display takes it untouched.
	if p := PlanVideo(hdr, "1080p", false, 5_000_000, 12_000_000, surroundCaps()); !p.Copy {
		t.Errorf("HDR to an HDR client = %+v, want a copy", p)
	}

	// A client without one gets a tone-mapped encode, never the raw PQ stream:
	// PQ code values read as gamma are the washed-out grey picture, not "SDR".
	sdr := surroundCaps()
	sdr.HDR = false
	p := PlanVideo(hdr, "1080p", false, 5_000_000, 12_000_000, sdr)
	if p.Copy {
		t.Fatal("an SDR client must not be handed a PQ stream")
	}
	if !p.Tonemap {
		t.Error("an HDR source that is re-encoded has to be tone mapped")
	}
}

func TestPlanVideo_DolbyVisionProfile5NeedsItsOwnDecoder(t *testing.T) {
	// Profile 5's base layer is in a private colour space: anything that decodes
	// it as HDR10 renders it green. Profile 8.1's base layer *is* HDR10, so an
	// ordinary HDR client can have it.
	p5 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 3840, Height: 2160, Codec: "hevc", PixFmt: "yuv420p10le",
		BitDepth: 10, ColorTransfer: "smpte2084", DoviProfile: 5,
	}}
	p81 := &ProbeResult{Video: &VideoStreamInfo{
		Width: 3840, Height: 2160, Codec: "hevc", PixFmt: "yuv420p10le",
		BitDepth: 10, ColorTransfer: "smpte2084", DoviProfile: 8, DoviBLCompatID: 1,
	}}
	hdrOnly := surroundCaps()

	if PlanVideo(p5, "2160p", false, 5_000_000, 0, hdrOnly).Copy {
		t.Error("profile 5 to a client without a Dolby Vision decoder must be re-encoded")
	}
	if !PlanVideo(p81, "2160p", false, 5_000_000, 0, hdrOnly).Copy {
		t.Error("profile 8.1 has an HDR10 base layer — an HDR client can take it")
	}

	dv := hdrOnly
	dv.DolbyVision = true
	if !PlanVideo(p5, "2160p", false, 5_000_000, 0, dv).Copy {
		t.Error("profile 5 to a Dolby Vision decoder is a copy")
	}
}

func TestH264Level_IsRaisedForFrameSizeAndRate(t *testing.T) {
	// 4.1 tops out at 1080p30. Declaring it on anything larger under-states the
	// stream in the SPS, which a hardware decoder is entitled to refuse — and it
	// refuses the way browser video always does: audio plays, nothing is drawn.
	cases := []struct {
		quality string
		fps     float64
		want    string
	}{
		{"720p", 24, "4.1"},
		{"720p", 60, "4.1"},
		{"1080p", 23.976, "4.1"},
		{"1080p", 29.97, "4.1"},
		{"1080p", 50, "4.2"},
		{"1080p", 59.94, "4.2"},
		{"2160p", 24, "5.1"},
		{"2160p", 60, "5.2"},
	}
	for _, c := range cases {
		probe := probeWith(3840, 2160, c.fps)
		if got := h264LevelFor(presetFor(c.quality), probe); got != c.want {
			t.Errorf("h264LevelFor(%s, %gfps) = %s, want %s", c.quality, c.fps, got, c.want)
		}
	}

	// The value has to reach the command line, not just the helper.
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/x.mkv", Quality: "2160p", TmpDir: "/tmp/x",
		Probe: probeWith(3840, 2160, 24), SegmentDuration: 2,
	})
	if level, _ := argValue(args, "-level"); level != "5.1" {
		t.Errorf("-level = %q for a 4K rendition, want 5.1", level)
	}
}

func TestEstimateBandwidthMatchesPresetCeiling(t *testing.T) {
	// The advertised bandwidth and the encoder's actual ceiling must not drift.
	got := EstimateBandwidth("720p")
	want := parseBitrate("3500k") + parseBitrate("160k")
	if got != want {
		t.Errorf("EstimateBandwidth(720p) = %d, want %d", got, want)
	}
	if EstimateBandwidth("nonsense") != EstimateBandwidth("720p") {
		t.Error("unknown quality should fall back to the 720p estimate")
	}
}

func TestParseBitrate(t *testing.T) {
	cases := map[string]int{
		"3500k": 3500000,
		"6M":    6000000,
		"800":   800,
		"":      0,
		"abc":   0,
	}
	for in, want := range cases {
		if got := parseBitrate(in); got != want {
			t.Errorf("parseBitrate(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestStereoDownmixFilter(t *testing.T) {
	// Whether to fold is PlanAudio's decision now — mono and stereo simply never
	// set Downmix. What is left here is the value itself, which is the same for
	// every surround layout: mix levels apply to whatever arrives, so there is no
	// channel index to get wrong and nothing to know in advance about the track.
	legacy := LegacyCapabilities()
	preset := presetFor("720p")
	for _, ch := range []int{0, 1, 2} {
		p := PlanAudio(probeWith(1280, 720, 24, AudioStreamInfo{Codec: "flac", Channels: ch}), 0, legacy, preset)
		if p.Downmix {
			t.Errorf("%dch needs no downmix", ch)
		}
	}
	for _, ch := range []int{3, 4, 6, 7, 8, 12} {
		p := PlanAudio(probeWith(1280, 720, 24, AudioStreamInfo{Codec: "flac", Channels: ch}), 0, legacy, preset)
		if !p.Downmix || p.Channels != 2 {
			t.Errorf("%dch to a stereo client = %+v, want a 2-channel downmix", ch, p)
		}
	}

	got := stereoDownmixFilter()
	if !strings.HasPrefix(got, "aresample=") {
		t.Errorf("the downmix should ride on the resampler, got %q", got)
	}
	// The centre carries the dialogue, and the whole point is that it stops
	// being 3 dB quieter than the fronts it sits between.
	if !strings.Contains(got, "center_mix_level=1.0") {
		t.Errorf("does not carry the centre at front level: %q", got)
	}
	// `pan` would need the layout to be known before the filter is built, and
	// the output layout is `-ac`'s job rather than this string's.
	if strings.Contains(got, "pan=") || strings.Contains(got, "out_chlayout") {
		t.Errorf("the downmix must not name channels or layouts: %q", got)
	}
}

func TestBuildFFmpegArgs_DownmixFilterOnlyOnSurroundRenditions(t *testing.T) {
	probe := &ProbeResult{
		Video: &VideoStreamInfo{Width: 1280, Height: 720, FrameRate: 24},
		Audio: []AudioStreamInfo{
			{Codec: "aac", Channels: 2},  // copied — no filter can apply
			{Codec: "eac3", Channels: 2}, // re-encoded, but already stereo
			{Codec: "dts", Channels: 6},  // 5.1 — the case the filter exists for
		},
	}
	// A legacy client, which is the only one that folds everything to stereo.
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/tmp/in.mkv", Quality: "720p", TmpDir: "/tmp/out",
		Probe: probe, SegmentDuration: 2, AudioTypedIndexes: []int{0, 1, 2},
	})

	for _, flag := range []string{"-filter:a:0", "-filter:a:1"} {
		if _, ok := argValue(args, flag); ok {
			t.Errorf("%s should carry no downmix filter", flag)
		}
	}
	v, ok := argValue(args, "-filter:a:2")
	if !ok {
		t.Fatal("the 5.1 rendition should carry a downmix filter")
	}
	if !strings.Contains(v, "center_mix_level=1.0") {
		t.Errorf("got %q", v)
	}
}

func TestVideoFilterChain_ToneMapsOnlyWhenEncodingAndOnlyWhenPossible(t *testing.T) {
	setFilterSetForTest("zscale", "tonemap", "scale", "overlay")
	probe := &ProbeResult{Video: &VideoStreamInfo{
		Width: 3840, Height: 2160, Codec: "hevc", PixFmt: "yuv420p10le",
		BitDepth: 10, ColorTransfer: "smpte2084", FrameRate: 24,
	}}

	// Encoding an HDR source down to 1080p: scale first (everything after it
	// then runs on a quarter of the pixels), tone map second.
	chain := videoFilterChain(TranscodeOptions{
		Probe: probe,
		Video: VideoPlan{Tonemap: true},
	}, presetFor("1080p"))
	if !strings.Contains(chain, "scale=w=1920") {
		t.Errorf("chain should scale: %q", chain)
	}
	if !strings.Contains(chain, "tonemap=tonemap=hable") {
		t.Errorf("chain should tone map: %q", chain)
	}
	if strings.Index(chain, "scale=w=1920") > strings.Index(chain, "tonemap=") {
		t.Errorf("scaling must come before tone mapping: %q", chain)
	}

	// A copied picture is never filtered — there is nothing to filter, the
	// frames are not being decoded.
	if got := videoFilterChain(TranscodeOptions{
		Probe: probe,
		Video: VideoPlan{Copy: true},
	}, presetFor("2160p")); got != "" {
		t.Errorf("copy path must carry no filter, got %q", got)
	}

	// An FFmpeg without zimg gets no tone mapping rather than a filter graph it
	// would reject — which would kill the session instead of degrading it.
	setFilterSetForTest("scale", "overlay")
	got := videoFilterChain(TranscodeOptions{
		Probe: probe,
		Video: VideoPlan{Tonemap: true},
	}, presetFor("2160p"))
	if strings.Contains(got, "tonemap") || strings.Contains(got, "zscale") {
		t.Errorf("no zimg means no tone-mapping filter, got %q", got)
	}
}

func TestBuildFFmpegArgs_ToneMappedOutputIsTaggedBT709(t *testing.T) {
	setFilterSetForTest("zscale", "tonemap", "scale")
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/x.mkv", Quality: "1080p", TmpDir: "/tmp/x", SegmentDuration: 2,
		Probe: &ProbeResult{Video: &VideoStreamInfo{
			Width: 3840, Height: 2160, Codec: "hevc", PixFmt: "yuv420p10le",
			BitDepth: 10, ColorTransfer: "smpte2084", FrameRate: 24,
		}},
		Video: VideoPlan{Tonemap: true},
	})
	// Untagged frames out of an HDR source make a player fall back to the
	// container's metadata, which still says BT.2020 PQ — and convert a picture
	// that has already been converted.
	for flag, want := range map[string]string{
		"-colorspace": "bt709", "-color_primaries": "bt709", "-color_trc": "bt709",
	} {
		if got, _ := argValue(args, flag); got != want {
			t.Errorf("%s = %q, want %q", flag, got, want)
		}
	}
}

func TestBuildFFmpegArgs_FMP4SessionsPublishAnInitSegment(t *testing.T) {
	caps := surroundCaps()
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/x.mkv", Quality: "1080p", TmpDir: "/tmp/x", SegmentDuration: 2,
		Probe:             probeWith(1920, 1080, 24, AudioStreamInfo{Codec: "eac3", Channels: 6}),
		AudioTypedIndexes: []int{0},
		Video:             VideoPlan{Copy: true},
		Caps:              caps,
	})
	if got, _ := argValue(args, "-hls_segment_type"); got != "fmp4" {
		t.Errorf("-hls_segment_type = %q, want fmp4", got)
	}
	if got, _ := argValue(args, "-hls_fmp4_init_filename"); got != "init_%v.mp4" {
		t.Errorf("-hls_fmp4_init_filename = %q", got)
	}
	if got, _ := argValue(args, "-hls_segment_filename"); !strings.HasSuffix(got, ".m4s") {
		t.Errorf("fMP4 segments must be named .m4s, got %q", got)
	}

	// And a legacy session keeps writing MPEG-TS, with no fMP4 options at all.
	legacy := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/x.mkv", Quality: "1080p", TmpDir: "/tmp/x", SegmentDuration: 2,
		Probe: probeWith(1920, 1080, 24), Video: VideoPlan{Copy: true},
	})
	if hasArg(legacy, "-hls_segment_type") {
		t.Error("a legacy session must not switch container")
	}
	if got, _ := argValue(legacy, "-hls_segment_filename"); !strings.HasSuffix(got, ".ts") {
		t.Errorf("legacy segments must stay .ts, got %q", got)
	}
}
