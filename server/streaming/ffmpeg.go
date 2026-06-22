package streaming

import (
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"strconv"
	"strings"
)

// VideoStreamInfo holds metadata about a video stream.
type VideoStreamInfo struct {
	Index  int    `json:"index"`
	Codec  string `json:"codec_name"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

// AudioStreamInfo holds metadata about an audio stream.
type AudioStreamInfo struct {
	Index    int    `json:"index"`
	Codec    string `json:"codec_name"`
	Language string `json:"language"`
	Title    string `json:"title"`
}

// SubtitleStreamInfo holds metadata about a subtitle stream.
type SubtitleStreamInfo struct {
	Index    int    `json:"index"`
	Codec    string `json:"codec_name"`
	Language string `json:"language"`
	Title    string `json:"title"`
}

// ProbeResult holds the parsed stream information from ffprobe.
type ProbeResult struct {
	Video     *VideoStreamInfo
	Audio     []AudioStreamInfo
	Subtitles []SubtitleStreamInfo
	Duration  float64 // total media duration in seconds
}

// qualityPresets maps quality labels to resolution dimensions.
var qualityPresets = map[string]struct{ W, H int }{
	"360p":  {640, 360},
	"480p":  {854, 480},
	"720p":  {1280, 720},
	"1080p": {1920, 1080},
}

// tsCompatibleAudioCodecs lists codecs that can be muxed into MPEG-TS without re-encoding.
var tsCompatibleAudioCodecs = map[string]bool{
	"aac":  true,
	"ac3":  true,
	"mp3":  true,
	"mp2":  true,
}

// IsAudioTSCompatible returns true if the codec can be copied into a .ts container.
func IsAudioTSCompatible(codec string) bool {
	return tsCompatibleAudioCodecs[strings.ToLower(codec)]
}

// ProbeTracks runs ffprobe on the input file and returns stream metadata.
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
			Index       int    `json:"index"`
			CodecType   string `json:"codec_type"`
			CodecName   string `json:"codec_name"`
			Width       int    `json:"width"`
			Height      int    `json:"height"`
			Tags        struct {
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

	for _, s := range ffResponse.Streams {
		switch s.CodecType {
		case "video":
			if result.Video == nil {
				result.Video = &VideoStreamInfo{
					Index:  s.Index,
					Codec:  s.CodecName,
					Width:  s.Width,
					Height: s.Height,
				}
			}
		case "audio":
			result.Audio = append(result.Audio, AudioStreamInfo{
				Index:    s.Index,
				Codec:    s.CodecName,
				Language: s.Tags.Language,
				Title:    s.Tags.Title,
			})
		case "subtitle":
			// Only text-based subtitles (subrip, ass, mov_text, webvtt)
			// Skip image-based (pgssub, dvd_subtitle, hdmv_pgs_subtitle)
			if isTextSubtitle(s.CodecName) {
				result.Subtitles = append(result.Subtitles, SubtitleStreamInfo{
					Index:    s.Index,
					Codec:    s.CodecName,
					Language: s.Tags.Language,
					Title:    s.Tags.Title,
				})
			}
		}
	}

	result.Duration = parseDuration(ffResponse.Format.Duration)

	return result, nil
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

func isTextSubtitle(codec string) bool {
	switch strings.ToLower(codec) {
	case "subrip", "ass", "ssa", "mov_text", "webvtt", "srt":
		return true
	default:
		return false
	}
}

// BuildFFmpegArgs constructs the FFmpeg command-line arguments for HLS transcoding.
func BuildFFmpegArgs(inputPath, quality, startSeconds, tmpDir string, probe *ProbeResult) []string {
	preset, ok := qualityPresets[quality]
	if !ok {
		preset = qualityPresets["720p"]
	}

	args := []string{}

	// Fast seek to start position
	if startSeconds != "" && startSeconds != "0" {
		args = append(args, "-ss", startSeconds)
	}

	// Input
	args = append(args, "-i", inputPath)

	// Video: transcode to target resolution with libx264
	args = append(args,
		"-map", "0:v:0",
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-crf", "24",
		"-vf", fmt.Sprintf("scale=%d:%d", preset.W, preset.H),
		"-force_key_frames", "expr:gte(t,n_forced*2)",
		"-threads", "4",
	)

	// Audio: copy if TS-compatible, otherwise transcode to AAC
	allCompatible := true
	if probe != nil {
		for _, a := range probe.Audio {
			if !IsAudioTSCompatible(a.Codec) {
				allCompatible = false
				break
			}
		}
	}

	if allCompatible {
		args = append(args, "-map", "0:a?", "-c:a", "copy")
	} else {
		args = append(args, "-map", "0:a?", "-c:a", "aac", "-b:a", "192k")
	}

	// HLS output settings
	// Growing playlist (hls_list_size 0, no delete_segments) so the player sees
	// the full transcoded timeline and can seek within already-generated segments.
	args = append(args,
		"-f", "hls",
		"-hls_time", "2",
		"-hls_list_size", "0",
		"-hls_flags", "independent_segments",
		"-hls_segment_filename", tmpDir+"/seg_%03d.ts",
		tmpDir+"/variant.m3u8",
	)

	return args
}

// ExtractSubtitles extracts text subtitle streams to WebVTT files.
// This runs in a background goroutine and is non-blocking.
func ExtractSubtitles(inputPath, tmpDir string, probe *ProbeResult) {
	if probe == nil || len(probe.Subtitles) == 0 {
		return
	}

	for i, sub := range probe.Subtitles {
		go func(idx int, subIdx int) {
			outPath := fmt.Sprintf("%s/sub_%d.vtt", tmpDir, idx)
			cmd := exec.Command("ffmpeg",
				"-i", inputPath,
				"-map", fmt.Sprintf("0:s:%d", subIdx),
				"-c:s", "webvtt",
				outPath,
			)
			if err := cmd.Run(); err != nil {
				log.Printf("Subtitle extraction failed for stream %d: %v", subIdx, err)
			} else {
				log.Printf("Subtitle extraction completed: sub_%d.vtt", idx)
			}
		}(i, sub.Index)
	}
}

// EstimateBandwidth returns a rough bandwidth estimate in bits per second for a quality.
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

// MapAudioCodecToHLS returns the HLS codec string for a given audio codec.
func MapAudioCodecToHLS(codec string) string {
	switch strings.ToLower(codec) {
	case "aac":
		return "mp4a.40.2"
	case "ac3":
		return "ac-3"
	case "mp3":
		return "mp4a.40.34"
	case "mp2":
		return "mp4a.40.33"
	default:
		return "mp4a.40.2"
	}
}

// GetResolutionString returns the RESOLUTION attribute for the master playlist.
func GetResolutionString(quality string) string {
	preset, ok := qualityPresets[quality]
	if !ok {
		preset = qualityPresets["720p"]
	}
	return strconv.Itoa(preset.W) + "x" + strconv.Itoa(preset.H)
}
