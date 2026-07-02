package subtitles

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Matches WebVTT timestamps in both forms: "HH:MM:SS.mmm" and "MM:SS.mmm".
// The hours group is optional because ffmpeg omits it for cues under one hour.
var vttTimeRe = regexp.MustCompile(`(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{3})`)

// ShiftVTT rebases a WebVTT document by startSeconds: every cue is moved earlier
// by that amount, and cues that finish before the new zero are dropped. This
// keeps external subtitles aligned with an HLS stream whose timeline resets at
// the session start offset. Direct Play passes startSeconds <= 0 (no-op).
func ShiftVTT(content []byte, startSeconds int) []byte {
	if startSeconds <= 0 {
		return content
	}
	shiftMs := startSeconds * 1000

	text := strings.ReplaceAll(string(content), "\r\n", "\n")
	blocks := strings.Split(text, "\n\n")

	out := make([]string, 0, len(blocks))
	for i, block := range blocks {
		if i == 0 {
			out = append(out, block) // WEBVTT header
			continue
		}
		if strings.TrimSpace(block) == "" {
			continue
		}

		lines := strings.Split(block, "\n")
		timingIdx := -1
		for li, l := range lines {
			if strings.Contains(l, "-->") {
				timingIdx = li
				break
			}
		}
		if timingIdx == -1 {
			out = append(out, block) // NOTE/STYLE/REGION — keep verbatim
			continue
		}

		times := vttTimeRe.FindAllString(lines[timingIdx], 2)
		if len(times) < 2 {
			out = append(out, block)
			continue
		}

		startMs := parseVTTTime(times[0]) - shiftMs
		endMs := parseVTTTime(times[1]) - shiftMs
		if endMs <= 0 {
			continue // entirely before the window
		}
		if startMs < 0 {
			startMs = 0
		}

		timing := fmt.Sprintf("%s --> %s", formatVTTTime(startMs), formatVTTTime(endMs))
		if rest := strings.TrimSpace(tail(lines[timingIdx], times[1])); rest != "" {
			timing += " " + rest // preserve cue settings (align/position/…)
		}
		lines[timingIdx] = timing
		out = append(out, strings.Join(lines, "\n"))
	}

	return []byte(strings.Join(out, "\n\n"))
}

// tail returns whatever follows the last occurrence of sep in s.
func tail(s, sep string) string {
	idx := strings.LastIndex(s, sep)
	if idx < 0 {
		return ""
	}
	return s[idx+len(sep):]
}

func parseVTTTime(t string) int {
	m := vttTimeRe.FindStringSubmatch(t)
	if len(m) != 5 {
		return 0
	}
	h, _ := strconv.Atoi(m[1]) // empty (no hours) -> 0
	mn, _ := strconv.Atoi(m[2])
	s, _ := strconv.Atoi(m[3])
	ms, _ := strconv.Atoi(m[4])
	return ((h*60+mn)*60+s)*1000 + ms
}

func formatVTTTime(ms int) string {
	if ms < 0 {
		ms = 0
	}
	h := ms / 3600000
	ms -= h * 3600000
	mn := ms / 60000
	ms -= mn * 60000
	s := ms / 1000
	ms -= s * 1000
	return fmt.Sprintf("%02d:%02d:%02d.%03d", h, mn, s, ms)
}
