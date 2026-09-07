package streaming

import (
	"net/url"
	"strings"
)

// Capabilities is what a client says it can decode, and it is the whole reason
// this server can stop assuming.
//
// Every codec decision used to be written against one imaginary client: a
// browser that decodes H.264 8-bit and stereo AAC and nothing else. That client
// is real, but it is the *weakest* one — mpv on a desktop decodes essentially
// everything, ExoPlayer on a television passes Dolby Digital Plus straight to an
// amplifier, and both were being handed a re-encoded, stereo-folded, tone-mapped
// approximation of a file they could have played untouched.
//
// So the client now says what it can do and the server does the least damage
// compatible with that. A client that says nothing gets exactly the old
// behaviour — that is what the zero value below is for, and it is what keeps
// every already-installed build working.
type Capabilities struct {
	// Container is the segment format. It gates the codec lists as hard as the
	// decoder does: MPEG-TS has no stream type for VP9 or AV1, so declaring
	// them means nothing until the segments are fMP4.
	Container SegmentContainer
	// VideoCodecs / AudioCodecs hold canonical names (see canonicalVideoCodec).
	VideoCodecs map[string]bool
	AudioCodecs map[string]bool
	// MaxAudioChannels is how many channels the client's *output* can carry —
	// 2 for a phone, 6 or 8 for anything wired to an amplifier. It is the number
	// that decides whether a 5.1 track survives, and no server-side default can
	// know it.
	MaxAudioChannels int
	// MaxVideoBitDepth is 8 for a browser, 10 for anything with a modern
	// hardware decoder.
	MaxVideoBitDepth int
	// HDR reports a display that can be driven with PQ or HLG. A client without
	// it gets tone mapping rather than a washed-out picture.
	HDR bool
	// DolbyVision reports a decoder that understands the RPU metadata layer, not
	// merely an HDR display. It is a separate flag because only one profile
	// actually needs it — see needsDolbyVisionDecoder.
	DolbyVision bool
}

// SegmentContainer is the muxer the HLS segments are written with.
type SegmentContainer string

const (
	// ContainerTS is MPEG-TS: universal, and the reason HEVC/VP9/AV1 could never
	// be copied. Kept as the default so a client that declares nothing behaves
	// exactly as it did before capabilities existed.
	ContainerTS SegmentContainer = "ts"
	// ContainerFMP4 is fragmented MP4 (CMAF). Everything the modern codec list
	// needs a home for lives here, and so does HDR metadata.
	ContainerFMP4 SegmentContainer = "fmp4"
)

// SegmentExt is the file extension segments of this container are written with.
func (c SegmentContainer) SegmentExt() string {
	if c == ContainerFMP4 {
		return ".m4s"
	}
	return ".ts"
}

// LegacyCapabilities is what a client that declares nothing is assumed to have:
// the browser this server was originally written for, and nothing more.
//
// Being wrong in this direction costs CPU. Being wrong in the other direction
// costs the film — a stream a client cannot decode fails silently, as a spinner
// that never ends, which is the one outcome no amount of server logging helps
// the viewer with.
func LegacyCapabilities() Capabilities {
	return Capabilities{
		Container:        ContainerTS,
		VideoCodecs:      map[string]bool{"h264": true},
		AudioCodecs:      map[string]bool{"aac": true},
		MaxAudioChannels: 2,
		MaxVideoBitDepth: 8,
		HDR:              false,
		DolbyVision:      false,
	}
}

// ParseCapabilities reads a client's declaration off the /start query string.
//
//	?container=fmp4&vcodec=h264,hevc,av1&acodec=aac,ac3,eac3&channels=6&bitdepth=10&hdr=1
//
// Every parameter is optional and each one falls back to its legacy value on
// its own, so a client can widen exactly the axis it is sure about.
func ParseCapabilities(q url.Values) Capabilities {
	caps := LegacyCapabilities()

	if v := strings.ToLower(strings.TrimSpace(q.Get("container"))); v == string(ContainerFMP4) {
		caps.Container = ContainerFMP4
	}
	if list := parseCodecList(q.Get("vcodec"), canonicalVideoCodec); len(list) > 0 {
		caps.VideoCodecs = list
		// H.264 is not optional. Every encode this server can perform produces
		// it, so a client that omitted it would leave no legal fallback for a
		// file it cannot take untouched — and the failure would land as a
		// broken stream rather than as a rejected request.
		caps.VideoCodecs["h264"] = true
	}
	if list := parseCodecList(q.Get("acodec"), canonicalAudioCodec); len(list) > 0 {
		caps.AudioCodecs = list
		caps.AudioCodecs["aac"] = true // same reasoning, for the audio fallback
	}
	if n := atoiDefault(q.Get("channels"), 0); n > 0 {
		caps.MaxAudioChannels = clampInt(n, 1, 8)
	}
	if n := atoiDefault(q.Get("bitdepth"), 0); n > 0 {
		caps.MaxVideoBitDepth = clampInt(n, 8, 12)
	}
	caps.HDR = isTruthy(q.Get("hdr"))
	caps.DolbyVision = isTruthy(q.Get("dv"))
	// Dolby Vision without HDR is not a thing a display can be: the flag is
	// about the metadata layer on top of an HDR signal, so it implies the
	// signal. Accepting the pair as sent would let a typo produce a client that
	// is offered Dolby Vision and cannot show HDR at all.
	if caps.DolbyVision {
		caps.HDR = true
	}

	return caps
}

// CanCarryVideo reports whether the segment container has a place for a codec.
//
// This is a separate question from whether the client decodes it, and it is the
// one that used to be answered wrong: `-c:v copy` of VP9 into MPEG-TS makes
// FFmpeg refuse to write a header and exit before its first segment, so /start
// times out and the media never loads at all.
func (c Capabilities) CanCarryVideo(codec string) bool {
	switch c.Container {
	case ContainerFMP4:
		switch codec {
		case "h264", "hevc", "av1", "vp9":
			return true
		}
	default:
		switch codec {
		case "h264", "hevc":
			return true
		}
	}
	return false
}

// CanCarryAudio reports whether the segment container can hold a codec.
//
// TrueHD and DTS are absent from both lists on purpose. Neither has a mapping
// FFmpeg's fMP4 muxer will write, so a copy of one is a session that dies on
// startup; they reach the viewer decoded and re-encoded instead, which is the
// only thing this server can honestly offer for them.
func (c Capabilities) CanCarryAudio(codec string) bool {
	switch c.Container {
	case ContainerFMP4:
		switch codec {
		case "aac", "ac3", "eac3", "opus", "flac", "alac":
			return true
		}
	default:
		switch codec {
		case "aac", "ac3", "eac3", "mp3":
			return true
		}
	}
	return false
}

// DecodesVideo / DecodesAudio report what the client itself declared.
func (c Capabilities) DecodesVideo(codec string) bool { return c.VideoCodecs[codec] }
func (c Capabilities) DecodesAudio(codec string) bool { return c.AudioCodecs[codec] }

// canonicalVideoCodec folds the many spellings of one codec into the name this
// package compares against. The spellings are not interchangeable in the wild:
// ffprobe says "hevc", a browser's isTypeSupported says "hvc1", and an HLS
// CODECS attribute says "hev1".
func canonicalVideoCodec(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "h264", "avc", "avc1", "h.264", "x264":
		return "h264"
	case "hevc", "h265", "h.265", "hvc1", "hev1", "x265":
		return "hevc"
	case "av1", "av01":
		return "av1"
	case "vp9", "vp09":
		return "vp9"
	case "vp8":
		return "vp8"
	case "mpeg2video", "mpeg2":
		return "mpeg2video"
	default:
		return ""
	}
}

// canonicalAudioCodec does the same for audio, where the spread is worse: one
// format is "eac3" to ffprobe, "ec-3" to an MP4 box and "e-ac-3" to a person.
func canonicalAudioCodec(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "aac", "mp4a", "aac_latm", "he-aac":
		return "aac"
	case "ac3", "ac-3", "dolby digital":
		return "ac3"
	case "eac3", "ec-3", "e-ac-3", "eac-3", "dolby digital plus", "ddp":
		return "eac3"
	case "dts", "dca", "dts-hd", "dtshd":
		return "dts"
	case "truehd", "mlp":
		return "truehd"
	case "flac":
		return "flac"
	case "alac":
		return "alac"
	case "opus":
		return "opus"
	case "vorbis":
		return "vorbis"
	case "mp3", "mp2", "mp1":
		return "mp3"
	case "pcm", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_bluray", "pcm_dvd":
		return "pcm"
	default:
		return ""
	}
}

// parseCodecList turns "hevc,av1 , vp9" into a canonical set, dropping anything
// it does not recognise. An empty result means "the client said nothing usable",
// which the caller distinguishes from "the client said no".
func parseCodecList(raw string, canonical func(string) string) map[string]bool {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	out := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		if name := canonical(part); name != "" {
			out[name] = true
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func isTruthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
