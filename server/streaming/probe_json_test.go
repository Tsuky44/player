package streaming

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestProbeJSON_CarriesTheDerivedLabelsAndSurvivesARoundTrip(t *testing.T) {
	in := &ProbeResult{
		Version: probeVersion,
		Video: &VideoStreamInfo{
			Codec: "hevc", Width: 3840, Height: 2160, PixFmt: "yuv420p10le",
			ColorTransfer: "smpte2084", DoviProfile: 8, DoviBLCompatID: 1,
		},
		Audio: []AudioStreamInfo{
			{Codec: "eac3", Channels: 6, Profile: "Dolby Digital Plus + Dolby Atmos"},
			{Codec: "truehd", Channels: 8, Profile: "Dolby TrueHD + Dolby Atmos"},
			{Codec: "aac", Channels: 2},
		},
	}

	raw, err := MarshalProbeResult(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{
		`"hdr_format":"dolbyvision"`,
		`"spatial_format":"atmos"`,
		`"lossless":true`,
	} {
		if !strings.Contains(raw, want) {
			t.Errorf("missing %s in %s", want, raw)
		}
	}
	// The resolved depth, not the 0 the container did not state.
	if !strings.Contains(raw, `"bit_depth":10`) {
		t.Errorf("bit depth should be resolved from the pixel format: %s", raw)
	}

	// The derived fields are additions, not replacements: everything a decision
	// reads has to come back out of the cache unchanged.
	out, err := UnmarshalProbeResult(raw)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !out.Current() {
		t.Error("a freshly written probe must read back as current")
	}
	if out.Video.DoviProfile != 8 || out.Video.ColorTransfer != "smpte2084" ||
		out.Video.PixFmt != "yuv420p10le" {
		t.Errorf("video round-trip lost fields: %+v", out.Video)
	}
	if len(out.Audio) != 3 || out.Audio[0].Channels != 6 ||
		!strings.Contains(out.Audio[0].Profile, "Atmos") {
		t.Errorf("audio round-trip lost fields: %+v", out.Audio)
	}

	// An entry written before the current shape is a cache miss, not a trusted
	// answer — that is the whole job of the version stamp.
	var stale ProbeResult
	_ = json.Unmarshal([]byte(`{"video":{"codec_name":"h264"}}`), &stale)
	if stale.Current() {
		t.Error("an unversioned entry must not read as current")
	}
}

func TestSpatialFormat_NamesWhatRidesInsideTheCodec(t *testing.T) {
	cases := []struct {
		codec, profile, want string
	}{
		{"eac3", "Dolby Digital Plus + Dolby Atmos", "atmos"},
		{"truehd", "Dolby TrueHD + Dolby Atmos", "atmos"},
		{"dts", "DTS-HD MA + DTS:X", "dtsx"},
		{"eac3", "Dolby Digital Plus", ""},
		{"dts", "DTS-HD MA", ""},
		{"aac", "LC", ""},
	}
	for _, c := range cases {
		a := AudioStreamInfo{Codec: c.codec, Profile: c.profile}
		if got := a.SpatialFormat(); got != c.want {
			t.Errorf("%s/%q = %q, want %q", c.codec, c.profile, got, c.want)
		}
	}
}
