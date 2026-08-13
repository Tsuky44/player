package streaming

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// StreamingAnalysis holds seek/latency hints detected at index time.
type StreamingAnalysis struct {
	GOPSeconds float64
	Warnings   []string
}

// AnalyzeStreamingFile inspects a media file for common Direct Play bottlenecks.
// Results are logged; no automatic remux is performed.
func AnalyzeStreamingFile(path string) StreamingAnalysis {
	out := StreamingAnalysis{}
	ext := strings.ToLower(filepath.Ext(path))

	if ext == ".mp4" || ext == ".m4v" || ext == ".mov" {
		if !mp4LikelyFastStart(path) {
			out.Warnings = append(out.Warnings,
				"MP4 moov atom may be at end of file — run: ffmpeg -c copy -movflags +faststart")
		}
	}

	if gop, err := estimateMaxGOPSeconds(path); err == nil && gop > 0 {
		out.GOPSeconds = gop
		if gop > 5 {
			out.Warnings = append(out.Warnings,
				fmt.Sprintf("large keyframe interval (~%.1fs) — first frame / seeks may buffer longer", gop))
		}
	}

	return out
}

// LogAnalysis emits indexer warnings for a media file.
func LogAnalysis(mediaID int, title, path string, a StreamingAnalysis) {
	for _, w := range a.Warnings {
		log.Printf("Indexer: streaming hint media_id=%d title=%q: %s", mediaID, title, w)
	}
	if a.GOPSeconds > 0 {
		log.Printf("Indexer: media_id=%d estimated max GOP=%.2fs", mediaID, a.GOPSeconds)
	}
}

// mp4LikelyFastStart heuristically checks whether moov appears before mdat.
func mp4LikelyFastStart(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return true
	}
	defer f.Close()

	buf := make([]byte, 262144)
	n, err := f.Read(buf)
	if err != nil && n == 0 {
		return true
	}
	chunk := string(buf[:n])
	mdat := strings.Index(chunk, "mdat")
	moov := strings.Index(chunk, "moov")
	if mdat >= 0 && moov >= 0 && mdat < moov {
		return false
	}
	return true
}

// estimateMaxGOPSeconds reads keyframe timestamps in the first 60s of video.
//
// This inspects PACKETS, not frames: keyframe positions are carried by the
// container's packet flags, so ffprobe only has to demux — never decode. The
// previous `-show_frames` form decoded 60s of video (~20s of CPU on a 1080p
// file) and asked for `pkt_pts_time`, a field removed from ffprobe in 5.x, so
// it always parsed to nothing. Packet flags are ~290x cheaper and actually work.
func estimateMaxGOPSeconds(path string) (float64, error) {
	cmd := exec.Command("ffprobe",
		"-v", "error",
		"-select_streams", "v:0",
		"-read_intervals", "0%+60",
		"-show_packets",
		"-show_entries", "packet=pts_time,flags",
		"-of", "csv=p=0",
		path,
	)
	out, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	var keyTimes []float64
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Rows look like "10.417000,K__" — flags carry 'K' on keyframe packets.
		parts := strings.Split(line, ",")
		if len(parts) < 2 {
			continue
		}
		if !strings.Contains(parts[len(parts)-1], "K") {
			continue
		}
		t, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		if err != nil {
			continue
		}
		keyTimes = append(keyTimes, t)
	}
	if len(keyTimes) < 2 {
		return 0, nil
	}

	maxGap := 0.0
	for i := 1; i < len(keyTimes); i++ {
		gap := keyTimes[i] - keyTimes[i-1]
		if gap > maxGap {
			maxGap = gap
		}
	}
	return maxGap, nil
}
