package streaming

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

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
	Video     *VideoStreamInfo     `json:"video"`
	Audio     []AudioStreamInfo    `json:"audio"`
	Subtitles []SubtitleStreamInfo `json:"subtitles"`
	Duration  float64              `json:"duration"` // total media duration in seconds
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
		Streams []struct {
			Index        int    `json:"index"`
			CodecType    string `json:"codec_type"`
			CodecName    string `json:"codec_name"`
			Width        int    `json:"width"`
			Height       int    `json:"height"`
			PixFmt       string `json:"pix_fmt"`
			Channels     int    `json:"channels"`
			AvgFrameRate string `json:"avg_frame_rate"`
			RFrameRate   string `json:"r_frame_rate"`
			Disposition  struct {
				Default int `json:"default"`
				Forced  int `json:"forced"`
			} `json:"disposition"`
			Tags struct {
				Language string `json:"language"`
				Title    string `json:"title"`
			} `json:"tags"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}

	if err := json.Unmarshal(output, &ffResponse); err != nil {
		return nil, fmt.Errorf("failed to parse ffprobe output: %w", err)
	}

	result := &ProbeResult{}
	audioTyped := 0
	subTyped := 0

	for _, s := range ffResponse.Streams {
		switch s.CodecType {
		case "video":
			// Skip cover-art / thumbnail streams (mjpeg/png attached pictures).
			if result.Video == nil && !isAttachedPicture(s.CodecName) {
				fps := parseFrameRate(s.AvgFrameRate)
				if fps <= 0 {
					fps = parseFrameRate(s.RFrameRate)
				}
				// An empty PixFmt has to mean "probed before this field existed",
				// because that is what invalidates a cached entry. A stream ffprobe
				// genuinely reports no pixel format for gets an explicit sentinel
				// instead, so it is never mistaken for stale data and re-probed on
				// every single session start.
				pixFmt := s.PixFmt
				if pixFmt == "" {
					pixFmt = "unknown"
				}
				result.Video = &VideoStreamInfo{
					Index:     s.Index,
					Codec:     s.CodecName,
					Width:     s.Width,
					Height:    s.Height,
					FrameRate: fps,
					PixFmt:    pixFmt,
				}
			}
		case "audio":
			result.Audio = append(result.Audio, AudioStreamInfo{
				Index:      s.Index,
				TypedIndex: audioTyped,
				Codec:      s.CodecName,
				Language:   s.Tags.Language,
				Title:      s.Tags.Title,
				Channels:   s.Channels,
				Default:    s.Disposition.Default == 1,
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
