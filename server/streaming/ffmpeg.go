package streaming

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
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

// sanitizeVSM removes characters that would break the -var_stream_map syntax,
// where entries are separated by spaces and key/value pairs by commas.
func sanitizeVSM(s string) string {
	r := strings.NewReplacer(" ", "_", ",", "_", "\"", "")
	return r.Replace(s)
}

// BuildFFmpegArgs constructs the FFmpeg command-line arguments for an HLS
// transcode with one video, one audio, and multiple subtitle tracks.
// FFmpeg generates:
//   - master.m3u8 + stream_0.m3u8 : video + single audio (H.264 + AAC)
//   - sub_N.m3u8 + sub_N_*.vtt    : one WebVTT segment playlist per text subtitle
//
// Only the selected audio track (audioIndex) is transcoded to keep CPU usage
// low. Switching audio tracks recreates the session client-side. Subtitles are
// all generated in the same process and exposed as native HLS renditions.
func BuildFFmpegArgs(inputPath, quality, startSeconds, tmpDir string, probe *ProbeResult, audioIndex int) []string {
	preset, ok := qualityPresets[quality]
	if !ok {
		preset = qualityPresets["720p"]
	}

	args := []string{}

	var startVal int
	if startSeconds != "" {
		fmt.Sscanf(startSeconds, "%d", &startVal)
	}

	// Single input seek (keyframe-accurate, fast). Using one input -ss keeps the
	// HLS output and the subtitle segment outputs on the same reset timeline, so
	// subtitles stay in sync with the video.
	if startVal > 0 {
		args = append(args, "-ss", fmt.Sprintf("%d", startVal))
	}
	args = append(args, "-i", inputPath)

	// --- Stream mapping ---
	// Video (always first)
	args = append(args, "-map", "0:v:0")

	// Audio: map only the selected audio track (by audioIndex). This keeps
	// CPU usage low — encoding multiple audio tracks simultaneously was the
	// main cause of the 8-minute transcoding delay on 4K HDR sources.
	if probe != nil && audioIndex >= 0 && audioIndex < len(probe.Audio) {
		args = append(args, "-map", fmt.Sprintf("0:%d", probe.Audio[audioIndex].Index))
	} else {
		args = append(args, "-map", "0:a:0?")
	}

	// --- Codecs ---
	// Force 8-bit 4:2:0 (yuv420p) so 10-bit HEVC sources don't produce a 10-bit
	// H.264 "High 10" stream, which most HLS clients cannot decode.
	// Tuned for fast startup on a many-core CPU (no GPU): ultrafast + zerolatency
	// removes lookahead/B-frames so the first segments are produced almost
	// immediately, and fast_bilinear scaling is cheaper than the default bicubic.
	args = append(args,
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-tune", "zerolatency",
		"-crf", "23",
		"-pix_fmt", "yuv420p",
		"-vf", fmt.Sprintf("scale=%d:%d:flags=fast_bilinear", preset.W, preset.H),
		"-g", "48",
		"-force_key_frames", "expr:gte(t,n_forced*2)",
		"-threads", "0",
	)
	// Audio: always transcode to AAC for HLS reliability (TrueHD/DTS cannot be
	// muxed into HLS audio renditions, and mixing copy/transcode is fragile).
	args = append(args, "-c:a", "aac", "-b:a", "192k")
	// Drop subtitles from the main process — they are generated separately (see
	// ExtractSubtitles) so the video transcode stays lean and never stalls
	// waiting on sparse subtitle packets.
	args = append(args, "-sn", "-max_muxing_queue_size", "1024")

	// --- var_stream_map (single video + single audio) ---
	// Only one audio rendition — switching audio recreates the session.
	var vsm strings.Builder
	vsm.WriteString("v:0,agroup:aud a:0,agroup:aud,default:yes")
	if probe != nil && audioIndex >= 0 && audioIndex < len(probe.Audio) {
		lang := probe.Audio[audioIndex].Language
		if lang == "" {
			lang = "und"
		}
		name := probe.Audio[audioIndex].Title
		if name == "" {
			name = fmt.Sprintf("Audio %d", audioIndex+1)
		}
		fmt.Fprintf(&vsm, ",language:%s,name:%s", sanitizeVSM(lang), sanitizeVSM(name))
	}

	// --- HLS output (video + audio) ---
	// FFmpeg writes master.m3u8 and stream_%v.m3u8 (+ segments) into tmpDir.
	args = append(args,
		"-f", "hls",
		"-hls_time", "2",
		"-hls_list_size", "0",
		"-hls_flags", "independent_segments",
		"-master_pl_name", "master.m3u8",
		"-var_stream_map", vsm.String(),
		"-hls_segment_filename", tmpDir+"/stream_%v_%03d.ts",
		tmpDir+"/stream_%v.m3u8",
	)

	return args
}

// subtitleIntermediateCodec returns the best intermediate codec to extract a
// given source subtitle codec to before converting it to WebVTT.
func subtitleIntermediateCodec(sourceCodec string) string {
	switch strings.ToLower(sourceCodec) {
	case "webvtt":
		return "webvtt"
	case "subrip", "srt":
		return "srt"
	case "ass", "ssa":
		return "ass"
	default:
		return "srt"
	}
}

// ExtractSubtitles extracts each text subtitle track to a single full WebVTT
// file in its own lightweight FFmpeg process (no video decoding involved, so
// it is near-instant) and writes a one-segment HLS playlist (sub_N.m3u8) that
// references it. This decouples subtitles from the heavy video transcode
// (Jellyfin-style) so subtitle switching is instant and never stalls the
// video pipeline. startSeconds applies the same input seek as the video so the
// subtitle timeline matches the reset HLS timeline. totalDuration is the full
// media duration in seconds (used for the playlist EXTINF).
func ExtractSubtitles(inputPath, tmpDir string, probe *ProbeResult, startSeconds int, totalDuration float64) *sync.WaitGroup {
	wg := &sync.WaitGroup{}
	if probe == nil || len(probe.Subtitles) == 0 {
		return wg
	}

	// Remaining duration covered by the extracted subtitles (timeline reset to 0).
	remaining := totalDuration - float64(startSeconds)
	if remaining <= 0 {
		remaining = totalDuration
	}

	for i, sub := range probe.Subtitles {
		// Write the one-segment playlist up-front so it always exists when the
		// player requests it, even before the .vtt has finished extracting.
		writeSubtitlePlaylist(tmpDir, i, remaining)

		wg.Add(1)
		go func(idx int, subIdx int, subCodec string) {
			defer wg.Done()
			outPath := fmt.Sprintf("%s/sub_%d.vtt", tmpDir, idx)

			// Optional input seek so subtitle timestamps reset to ~0, matching the
			// video HLS timeline (which uses the same -ss before -i).
			seek := func() []string {
				if startSeconds > 0 {
					return []string{"-ss", fmt.Sprintf("%d", startSeconds)}
				}
				return nil
			}

			intermediateCodec := subtitleIntermediateCodec(subCodec)
			if intermediateCodec == "webvtt" {
				// Direct extraction is enough for WebVTT sources.
				args := append(seek(),
					"-i", inputPath,
					"-map", fmt.Sprintf("0:s:%d", subIdx),
					"-c:s", "webvtt",
					outPath,
				)
				cmd := exec.Command("ffmpeg", args...)
				var stderr bytes.Buffer
				cmd.Stderr = &stderr
				if err := cmd.Run(); err != nil {
					log.Printf("Subtitle extraction failed for stream %d: %v (stderr: %s)", subIdx, err, stderr.String())
				} else {
					log.Printf("Subtitle extraction completed: sub_%d.vtt", idx)
				}
				return
			}

			// For other text formats, extract to the original format first then
			// convert to WebVTT. This avoids "text to text or bitmap to bitmap"
			// errors when the source has Matroska time offsets or codec quirks.
			tmpPath := fmt.Sprintf("%s/sub_%d.%s", tmpDir, idx, intermediateCodec)
			extractArgs := append(seek(),
				"-i", inputPath,
				"-map", fmt.Sprintf("0:s:%d", subIdx),
				"-c:s", "copy",
				tmpPath,
			)
			extractCmd := exec.Command("ffmpeg", extractArgs...)
			var extractStderr bytes.Buffer
			extractCmd.Stderr = &extractStderr
			if err := extractCmd.Run(); err != nil {
				log.Printf("Subtitle extraction failed for stream %d: %v (stderr: %s)", subIdx, err, extractStderr.String())
				return
			}

			convertCmd := exec.Command("ffmpeg",
				"-i", tmpPath,
				"-c:s", "webvtt",
				outPath,
			)
			var convertStderr bytes.Buffer
			convertCmd.Stderr = &convertStderr
			if err := convertCmd.Run(); err != nil {
				log.Printf("Subtitle conversion failed for stream %d: %v (stderr: %s)", subIdx, err, convertStderr.String())
				os.Remove(tmpPath)
				return
			}

			os.Remove(tmpPath)
			log.Printf("Subtitle extraction completed: sub_%d.vtt", idx)
		}(i, sub.Index, sub.Codec)
	}

	return wg
}

// writeSubtitlePlaylist writes a VOD HLS playlist that references the full
// sub_<idx>.vtt file as a single segment covering the whole duration.
func writeSubtitlePlaylist(tmpDir string, idx int, duration float64) {
	if duration <= 0 {
		duration = 86400 // 24h fallback
	}
	target := int(duration) + 1
	content := fmt.Sprintf(
		"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:%.3f,\nsub_%d.vtt\n#EXT-X-ENDLIST\n",
		target, duration, idx,
	)
	playlistPath := fmt.Sprintf("%s/sub_%d.m3u8", tmpDir, idx)
	if err := os.WriteFile(playlistPath, []byte(content), 0644); err != nil {
		log.Printf("Subtitle playlist write failed for sub_%d: %v", idx, err)
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
