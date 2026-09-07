package streaming

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// probeVersion stamps every ProbeResult with the shape of the data it carries.
//
// The cached probe in medias.tracks_json is what the copy-or-encode decision is
// made from, and that decision now reads fields — bit depth, colour transfer,
// audio profile — that entries written by an older build simply do not have.
// A missing field is indistinguishable from a field whose answer is "no", so a
// stale entry would quietly send an HDR HEVC file down the SDR encoder forever.
//
// Bumping this number is therefore the one way to say "re-probe": both caches
// treat an entry below the current version as a miss. It replaces the
// PixFmt-is-empty sentinel, which could only ever detect one generation of
// staleness.
const probeVersion = 2

// VideoStreamInfo holds metadata about the primary video stream.
type VideoStreamInfo struct {
	Index  int    `json:"index"`
	Codec  string `json:"codec_name"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	// FrameRate is the average frame rate in fps (0 when unknown). Used to size
	// the encoder GOP so a 60fps source doesn't get 2.5x more keyframes than
	// the segment layout needs.
	FrameRate float64 `json:"frame_rate"`
	// PixFmt is FFmpeg's pixel format, e.g. "yuv420p" or "yuv420p10le".
	//
	// It is what separates a stream the browser can be handed untouched from one
	// that must be re-encoded: no browser decodes 10-bit H.264 (High 10), and
	// passing it through produces a black picture with no error. Empty on media
	// probed before this field existed, which the copy decision treats as "do
	// not risk it".
	PixFmt string `json:"pix_fmt"`
	// Profile is the codec profile as ffprobe names it ("High", "Main 10").
	Profile string `json:"profile"`
	// BitDepth is bits per sample, derived from bits_per_raw_sample when the
	// container states it and from PixFmt otherwise. 0 means unknown.
	BitDepth int `json:"bit_depth"`
	// The three colour tags that, together, say whether this is HDR.
	ColorTransfer  string `json:"color_transfer"`
	ColorPrimaries string `json:"color_primaries"`
	ColorSpace     string `json:"color_space"`
	// DoviProfile is the Dolby Vision profile from the stream's DOVI
	// configuration record (5, 7, 8...), or 0 when the stream carries none.
	DoviProfile int `json:"dovi_profile"`
	// DoviBLCompatID is the base-layer compatibility id of that record. It is
	// what separates a Dolby Vision stream a non-DV display can still show
	// correctly (1 = HDR10-compatible, 4 = HLG-compatible, 2 = SDR) from one
	// that would come out visibly wrong — profile 5, whose base layer is in a
	// private colour space and renders green and washed out anywhere else.
	DoviBLCompatID int `json:"dovi_bl_compat_id"`
	// HDR10Plus reports dynamic SMPTE 2094-40 metadata on the stream.
	HDR10Plus bool `json:"hdr10_plus"`
}

// EightBit420 reports whether the stream is plain 8-bit 4:2:0, the only
// combination every target browser decodes.
//
// Chroma subsampling has to be checked alongside bit depth because it fails the
// same way and just as silently. A browser's H.264 decoder handles 4:2:0 and
// nothing else: High 10 (10-bit) and High 4:2:2 are both rejected without an
// error anywhere — the segments append to the source buffer, the audio plays,
// and no picture is ever drawn. 4:2:2 used to pass this check, which made a
// 4:2:2 master the one kind of file that reached the viewer as sound over a
// permanent spinner.
func (v *VideoStreamInfo) EightBit420() bool {
	switch strings.ToLower(v.PixFmt) {
	case "yuv420p", "yuvj420p", "nv12", "nv21":
		return true
	default:
		return false
	}
}

// Chroma420 reports 4:2:0 subsampling at any bit depth.
//
// This is the check that belongs next to a client's declared bit-depth ceiling.
// EightBit420 fuses "8-bit" and "4:2:0" because the browsers it was written for
// need both; a client that says it decodes 10-bit HEVC needs only the second
// half, and asking it the fused question would send every Main 10 file to the
// encoder it was meant to skip.
func (v *VideoStreamInfo) Chroma420() bool {
	f := strings.ToLower(v.PixFmt)
	switch f {
	case "nv12", "nv21", "p010le", "p010be", "p012le", "p012be":
		return true
	}
	return strings.HasPrefix(f, "yuv420p") || strings.HasPrefix(f, "yuvj420p")
}

// DepthOrDefault is the stream's bit depth, assuming 8 when nothing said.
//
// The pixel format is consulted before that assumption is made, because it is
// the field that actually answers this: bits_per_raw_sample is absent from most
// Matroska files, and "yuv420p10le" is unambiguous about its ten bits. Assuming
// 8 without looking is how a Main 10 source ends up copied to a client that
// decodes 8-bit only — which fails silently, as a black picture with sound.
//
// Unknown still has to read as 8 rather than as "reject": a file that states
// neither is overwhelmingly an 8-bit one.
func (v *VideoStreamInfo) DepthOrDefault() int {
	if v.BitDepth > 0 {
		return v.BitDepth
	}
	if d := bitDepthOf("", v.PixFmt); d > 0 {
		return d
	}
	return 8
}

// HDRFormat names the high dynamic range format of the stream, or "" for SDR.
//
// The order is the order of specificity, because the formats are layered rather
// than exclusive: a Dolby Vision profile 8 stream is also HDR10, and an HDR10+
// stream is also HDR10. Naming the outermost layer is what the client needs —
// it is what the display will actually be driven with.
func (v *VideoStreamInfo) HDRFormat() string {
	switch {
	case v.DoviProfile > 0:
		return "dolbyvision"
	case v.HDR10Plus:
		return "hdr10plus"
	}
	switch strings.ToLower(v.ColorTransfer) {
	case "smpte2084", "smpte st 2084":
		return "hdr10"
	case "arib-std-b67":
		return "hlg"
	default:
		return ""
	}
}

// IsHDR reports whether the picture needs tone mapping to reach an SDR display.
func (v *VideoStreamInfo) IsHDR() bool { return v.HDRFormat() != "" }

// MarshalJSON adds the derived labels the client needs but should not have to
// re-derive: what makes a stream HDR is a rule, and a rule stated in two
// languages is a rule that will disagree with itself. The client reads
// hdr_format; this side stays the only place that decides what it means.
//
// The alias type is what stops this from recursing: it has the same fields and
// none of the methods, so marshalling it does not call back into here.
func (v VideoStreamInfo) MarshalJSON() ([]byte, error) {
	type alias VideoStreamInfo
	return json.Marshal(struct {
		alias
		HDRFormat string `json:"hdr_format"`
		BitDepth  int    `json:"bit_depth"`
	}{
		alias:     alias(v),
		HDRFormat: v.HDRFormat(),
		// Overrides the stored field with the resolved one, so a client never
		// sees the 0 that means "the container did not say".
		BitDepth: v.DepthOrDefault(),
	})
}

// AudioStreamInfo holds metadata about an audio stream.
//
// TypedIndex is the position of the stream among audio streams only
// (0-based), i.e. the N in FFmpeg's "0:a:N" mapping. It is what must be used
// for mapping, never the absolute container Index, because the absolute index
// counts video/subtitle/data streams too.
type AudioStreamInfo struct {
	Index      int    `json:"index"`       // absolute stream index in the container
	TypedIndex int    `json:"typed_index"` // index among audio streams (0:a:N)
	Codec      string `json:"codec_name"`
	Language   string `json:"language"`
	Title      string `json:"title"`
	Channels   int    `json:"channels"`
	Default    bool   `json:"default"`
	// Profile is what separates the formats that share a codec name. Atmos is
	// not a codec: it is an object bed carried inside E-AC-3 (as JOC) or inside
	// TrueHD, and ffprobe reports it here and nowhere else. Same for DTS, where
	// one codec_name covers plain DTS, DTS-HD MA and DTS:X.
	Profile string `json:"profile"`
	// ChannelLayout is ffprobe's layout name ("5.1(side)", "7.1"), for display.
	ChannelLayout string `json:"channel_layout"`
	SampleRate    int    `json:"sample_rate"`
	BitRate       int    `json:"bit_rate"`
}

// SpatialFormat names the object-based format carried inside the stream, or ""
// when the track is plain channel-based audio.
func (a *AudioStreamInfo) SpatialFormat() string {
	p := strings.ToLower(a.Profile)
	switch {
	case strings.Contains(p, "atmos"):
		return "atmos"
	case strings.Contains(p, "dts:x") || strings.Contains(p, "dts-x"):
		return "dtsx"
	default:
		return ""
	}
}

// Lossless reports whether the track is a bit-exact copy of its master.
//
// Worth knowing because it is exactly the set of formats where re-encoding is
// the most wasteful and passthrough the most valuable.
func (a *AudioStreamInfo) Lossless() bool {
	switch strings.ToLower(a.Codec) {
	case "truehd", "mlp", "flac", "alac", "pcm_s16le", "pcm_s24le", "pcm_s32le",
		"pcm_bluray", "pcm_dvd", "wavpack", "tta":
		return true
	case "dts":
		p := strings.ToLower(a.Profile)
		return strings.Contains(p, "ma") || strings.Contains(p, "dts:x")
	default:
		return false
	}
}

// MarshalJSON adds the derived labels, for the same reason VideoStreamInfo does.
func (a AudioStreamInfo) MarshalJSON() ([]byte, error) {
	type alias AudioStreamInfo
	return json.Marshal(struct {
		alias
		SpatialFormat string `json:"spatial_format"`
		Lossless      bool   `json:"lossless"`
	}{
		alias:         alias(a),
		SpatialFormat: a.SpatialFormat(),
		Lossless:      a.Lossless(),
	})
}

// SubtitleStreamInfo holds metadata about a subtitle stream.
//
// Image is true for bitmap subtitles (PGS, VOBSUB, DVB) that cannot be turned
// into WebVTT and therefore must be burned into the video when transcoding.
type SubtitleStreamInfo struct {
	Index      int    `json:"index"`       // absolute stream index in the container
	TypedIndex int    `json:"typed_index"` // index among subtitle streams (0:s:N)
	Codec      string `json:"codec_name"`
	Language   string `json:"language"`
	Title      string `json:"title"`
	Image      bool   `json:"image"`
	Default    bool   `json:"default"`
	Forced     bool   `json:"forced"`
}

// ProbeResult holds the parsed stream information from ffprobe.
type ProbeResult struct {
	// Version is probeVersion at the time this result was produced. See there.
	Version   int                  `json:"version"`
	Video     *VideoStreamInfo     `json:"video"`
	Audio     []AudioStreamInfo    `json:"audio"`
	Subtitles []SubtitleStreamInfo `json:"subtitles"`
	Duration  float64              `json:"duration"` // total media duration in seconds
}

// Current reports whether a probe carries everything today's decisions read.
// Both caches ask this before trusting a stored entry.
func (r *ProbeResult) Current() bool {
	return r != nil && r.Version >= probeVersion
}

// ffprobeStream mirrors the fields of ffprobe's -show_streams JSON that this
// package reads. Side data is included: -show_streams emits side_data_list on
// any stream that carries some, which is where Dolby Vision and HDR10+ live.
type ffprobeStream struct {
	Index            int    `json:"index"`
	CodecType        string `json:"codec_type"`
	CodecName        string `json:"codec_name"`
	Profile          string `json:"profile"`
	Width            int    `json:"width"`
	Height           int    `json:"height"`
	PixFmt           string `json:"pix_fmt"`
	BitsPerRawSample string `json:"bits_per_raw_sample"`
	ColorTransfer    string `json:"color_transfer"`
	ColorPrimaries   string `json:"color_primaries"`
	ColorSpace       string `json:"color_space"`
	Channels         int    `json:"channels"`
	ChannelLayout    string `json:"channel_layout"`
	SampleRate       string `json:"sample_rate"`
	BitRate          string `json:"bit_rate"`
	AvgFrameRate     string `json:"avg_frame_rate"`
	RFrameRate       string `json:"r_frame_rate"`
	Disposition      struct {
		Default int `json:"default"`
		Forced  int `json:"forced"`
	} `json:"disposition"`
	Tags struct {
		Language string `json:"language"`
		Title    string `json:"title"`
	} `json:"tags"`
	SideData []struct {
		Type string `json:"side_data_type"`
		// Dolby Vision configuration record.
		DvProfile          *int `json:"dv_profile"`
		DvBLSignalCompatID *int `json:"dv_bl_signal_compatibility_id"`
	} `json:"side_data_list"`
}

// ProbeTracks runs ffprobe on the input file and returns stream metadata.
// Subtitle indices are assigned per stream-type (0:s:N) so they map correctly
// regardless of how many audio/video streams precede them in the container.
func ProbeTracks(inputPath string) (*ProbeResult, error) {
	cmd := exec.Command("ffprobe",
		"-v", "quiet",
		"-print_format", "json",
		"-show_streams",
		"-show_format",
		inputPath,
	)

	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe failed: %w", err)
	}

	var ffResponse struct {
		Streams []ffprobeStream `json:"streams"`
		Format  struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}

	if err := json.Unmarshal(output, &ffResponse); err != nil {
		return nil, fmt.Errorf("failed to parse ffprobe output: %w", err)
	}

	result := &ProbeResult{Version: probeVersion}
	audioTyped := 0
	subTyped := 0

	for _, s := range ffResponse.Streams {
		switch s.CodecType {
		case "video":
			// Skip cover-art / thumbnail streams (mjpeg/png attached pictures).
			if result.Video == nil && !isAttachedPicture(s.CodecName) {
				result.Video = videoStreamFrom(s)
			}
		case "audio":
			result.Audio = append(result.Audio, AudioStreamInfo{
				Index:         s.Index,
				TypedIndex:    audioTyped,
				Codec:         s.CodecName,
				Language:      s.Tags.Language,
				Title:         s.Tags.Title,
				Channels:      s.Channels,
				Default:       s.Disposition.Default == 1,
				Profile:       s.Profile,
				ChannelLayout: s.ChannelLayout,
				SampleRate:    atoiOrZero(s.SampleRate),
				BitRate:       atoiOrZero(s.BitRate),
			})
			audioTyped++
		case "subtitle":
			// Every subtitle stream is listed (so the typed index keeps lining
			// up with 0:s:N), but image-based ones are flagged so the client can
			// request burn-in instead of an impossible WebVTT extraction.
			result.Subtitles = append(result.Subtitles, SubtitleStreamInfo{
				Index:      s.Index,
				TypedIndex: subTyped,
				Codec:      s.CodecName,
				Language:   s.Tags.Language,
				Title:      s.Tags.Title,
				Image:      !isTextSubtitle(s.CodecName),
				Default:    s.Disposition.Default == 1,
				Forced:     s.Disposition.Forced == 1,
			})
			subTyped++
		}
	}

	result.Duration = parseDuration(ffResponse.Format.Duration)
	return result, nil
}

// videoStreamFrom builds the primary video stream's metadata from one ffprobe
// stream entry.
func videoStreamFrom(s ffprobeStream) *VideoStreamInfo {
	fps := parseFrameRate(s.AvgFrameRate)
	if fps <= 0 {
		fps = parseFrameRate(s.RFrameRate)
	}
	// An empty PixFmt has to mean "probed before this field existed", because
	// that is what invalidates a cached entry. A stream ffprobe genuinely
	// reports no pixel format for gets an explicit sentinel instead, so it is
	// never mistaken for stale data and re-probed on every single session start.
	pixFmt := s.PixFmt
	if pixFmt == "" {
		pixFmt = "unknown"
	}

	v := &VideoStreamInfo{
		Index:          s.Index,
		Codec:          s.CodecName,
		Width:          s.Width,
		Height:         s.Height,
		FrameRate:      fps,
		PixFmt:         pixFmt,
		Profile:        s.Profile,
		BitDepth:       bitDepthOf(s.BitsPerRawSample, pixFmt),
		ColorTransfer:  s.ColorTransfer,
		ColorPrimaries: s.ColorPrimaries,
		ColorSpace:     s.ColorSpace,
	}

	for _, sd := range s.SideData {
		t := strings.ToLower(sd.Type)
		switch {
		case strings.Contains(t, "dovi") || strings.Contains(t, "dolby vision"):
			if sd.DvProfile != nil {
				v.DoviProfile = *sd.DvProfile
			}
			if sd.DvBLSignalCompatID != nil {
				v.DoviBLCompatID = *sd.DvBLSignalCompatID
			}
		case strings.Contains(t, "2094-40") || strings.Contains(t, "hdr10+"):
			v.HDR10Plus = true
		}
	}
	return v
}

// bitDepthOf resolves bits per sample from what the container stated, falling
// back to what the pixel format's name implies.
//
// bits_per_raw_sample is absent far more often than it is present — Matroska
// rarely carries it — so the pixel format is the field that actually answers
// this in practice. "yuv420p10le" is unambiguous about its ten bits.
func bitDepthOf(bitsPerRawSample, pixFmt string) int {
	if n := atoiOrZero(bitsPerRawSample); n > 0 {
		return n
	}
	f := strings.ToLower(pixFmt)
	switch {
	case strings.Contains(f, "12le"), strings.Contains(f, "12be"), strings.HasPrefix(f, "p012"):
		return 12
	case strings.Contains(f, "10le"), strings.Contains(f, "10be"), strings.HasPrefix(f, "p010"):
		return 10
	case f == "" || f == "unknown":
		return 0
	default:
		return 8
	}
}

// MarshalProbeResult serializes a probe result for DB storage.
func MarshalProbeResult(r *ProbeResult) (string, error) {
	b, err := json.Marshal(r)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// UnmarshalProbeResult restores a probe result from DB JSON.
func UnmarshalProbeResult(raw string) (*ProbeResult, error) {
	if raw == "" {
		return nil, fmt.Errorf("empty probe json")
	}
	var r ProbeResult
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// parseDuration parses a string like "123.456" into a float64.
func parseDuration(s string) float64 {
	if s == "" {
		return 0
	}
	d, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return d
}

// atoiOrZero parses one of ffprobe's numeric-string fields, which are absent
// (empty) far more often than they are malformed.
func atoiOrZero(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return n
}

// parseFrameRate turns an ffprobe rational ("24000/1001") into fps.
func parseFrameRate(s string) float64 {
	if s == "" || s == "0/0" {
		return 0
	}
	num, den, ok := strings.Cut(s, "/")
	if !ok {
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return 0
		}
		return v
	}
	n, err1 := strconv.ParseFloat(num, 64)
	d, err2 := strconv.ParseFloat(den, 64)
	if err1 != nil || err2 != nil || d == 0 {
		return 0
	}
	return n / d
}

func isTextSubtitle(codec string) bool {
	switch strings.ToLower(codec) {
	case "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text":
		return true
	default:
		return false
	}
}

func isAttachedPicture(codec string) bool {
	switch strings.ToLower(codec) {
	case "mjpeg", "png", "bmp", "gif":
		return true
	default:
		return false
	}
}
