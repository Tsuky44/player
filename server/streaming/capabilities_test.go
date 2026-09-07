package streaming

import (
	"net/url"
	"testing"
)

func TestParseCapabilities_SilenceMeansTheOldBehaviour(t *testing.T) {
	// The single most important case: an already-installed app build, or the
	// web player before it learned to declare anything, must be served exactly
	// what it was served before.
	got := ParseCapabilities(url.Values{})
	want := LegacyCapabilities()

	if got.Container != want.Container {
		t.Errorf("container = %q, want %q", got.Container, want.Container)
	}
	if got.MaxAudioChannels != 2 || got.MaxVideoBitDepth != 8 || got.HDR || got.DolbyVision {
		t.Errorf("= %+v, want the legacy ceilings", got)
	}
	if !got.DecodesVideo("h264") || got.DecodesVideo("hevc") {
		t.Errorf("video codecs = %v, want H.264 only", got.VideoCodecs)
	}
	if !got.DecodesAudio("aac") || got.DecodesAudio("eac3") {
		t.Errorf("audio codecs = %v, want AAC only", got.AudioCodecs)
	}
}

func TestParseCapabilities_EachAxisWidensOnItsOwn(t *testing.T) {
	// A client that is sure about one thing and silent about the rest must not
	// have the rest reset to something it never claimed.
	got := ParseCapabilities(url.Values{"channels": {"6"}})
	if got.MaxAudioChannels != 6 {
		t.Errorf("channels = %d, want 6", got.MaxAudioChannels)
	}
	if got.Container != ContainerTS || got.DecodesVideo("hevc") {
		t.Errorf("declaring channels must not widen anything else: %+v", got)
	}
}

func TestParseCapabilities_ReadsEverySpellingOfACodec(t *testing.T) {
	q := url.Values{
		"vcodec": {"avc1, hvc1 ,AV01,vp09"},
		"acodec": {"mp4a,ec-3,ac-3,DTS"},
	}
	got := ParseCapabilities(q)
	for _, name := range []string{"h264", "hevc", "av1", "vp9"} {
		if !got.DecodesVideo(name) {
			t.Errorf("video %q not recognised from %v", name, got.VideoCodecs)
		}
	}
	for _, name := range []string{"aac", "eac3", "ac3", "dts"} {
		if !got.DecodesAudio(name) {
			t.Errorf("audio %q not recognised from %v", name, got.AudioCodecs)
		}
	}
}

func TestParseCapabilities_TheFallbackCodecsAreNeverOptional(t *testing.T) {
	// Every encode this server can perform produces H.264 and AAC. A client
	// that omitted them would leave no legal fallback for a file it cannot take
	// untouched, and the failure would land as a broken stream rather than as a
	// rejected request.
	got := ParseCapabilities(url.Values{
		"vcodec": {"av1"},
		"acodec": {"opus"},
	})
	if !got.DecodesVideo("h264") {
		t.Error("H.264 must always be assumed — it is the only thing this server encodes")
	}
	if !got.DecodesAudio("aac") {
		t.Error("AAC must always be assumed, for the same reason")
	}
	if !got.DecodesVideo("av1") || !got.DecodesAudio("opus") {
		t.Error("what the client did declare must survive")
	}
}

func TestParseCapabilities_ClampsWhatItIsGiven(t *testing.T) {
	got := ParseCapabilities(url.Values{
		"channels": {"64"},
		"bitdepth": {"9999"},
	})
	if got.MaxAudioChannels != 8 {
		t.Errorf("channels = %d, want a ceiling of 8", got.MaxAudioChannels)
	}
	if got.MaxVideoBitDepth != 12 {
		t.Errorf("bitdepth = %d, want a ceiling of 12", got.MaxVideoBitDepth)
	}

	// Garbage falls back rather than producing a zero, which would read as
	// "this client can play nothing" and break the session outright.
	got = ParseCapabilities(url.Values{
		"channels": {"abc"},
		"vcodec":   {"betamax,laserdisc"},
	})
	if got.MaxAudioChannels != 2 {
		t.Errorf("channels = %d, want the legacy 2", got.MaxAudioChannels)
	}
	if !got.DecodesVideo("h264") || len(got.VideoCodecs) != 1 {
		t.Errorf("unrecognised codecs = %v, want the legacy list", got.VideoCodecs)
	}
}

func TestParseCapabilities_DolbyVisionImpliesHDR(t *testing.T) {
	// Dolby Vision is a metadata layer on top of an HDR signal, so a client
	// cannot have the first without the second. Accepting the pair as sent
	// would let a typo produce a client that is offered Dolby Vision and
	// cannot show HDR at all.
	got := ParseCapabilities(url.Values{"dv": {"1"}})
	if !got.DolbyVision || !got.HDR {
		t.Errorf("= %+v, want both set", got)
	}
}

func TestCanCarry_TheContainerVetoesIndependentlyOfTheDecoder(t *testing.T) {
	ts := Capabilities{Container: ContainerTS}
	fmp4 := Capabilities{Container: ContainerFMP4}

	for _, c := range []struct {
		codec     string
		ts, inMP4 bool
	}{
		{"h264", true, true},
		{"hevc", true, true},
		{"vp9", false, true},
		{"av1", false, true},
	} {
		if got := ts.CanCarryVideo(c.codec); got != c.ts {
			t.Errorf("MPEG-TS carries %s = %v, want %v", c.codec, got, c.ts)
		}
		if got := fmp4.CanCarryVideo(c.codec); got != c.inMP4 {
			t.Errorf("fMP4 carries %s = %v, want %v", c.codec, got, c.inMP4)
		}
	}

	// TrueHD and DTS have no mapping either muxer will write. A copy of one is
	// a session that dies on startup, so they must be refused by both.
	for _, codec := range []string{"truehd", "dts", "pcm"} {
		if ts.CanCarryAudio(codec) || fmp4.CanCarryAudio(codec) {
			t.Errorf("%s must not be considered muxable", codec)
		}
	}
	if !fmp4.CanCarryAudio("flac") || ts.CanCarryAudio("flac") {
		t.Error("FLAC belongs in fMP4 and nowhere near MPEG-TS")
	}
}
