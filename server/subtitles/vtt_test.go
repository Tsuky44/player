package subtitles

import (
	"strings"
	"testing"
)

// Real-world ffmpeg output for a sub-1h source uses MM:SS.mmm (no hours field).
const sampleVTT = `WEBVTT

00:03.717 --> 00:07.929
UNE SÉRIE NETFLIX

01:03.526 --> 01:05.820
Intro dialogue (should be dropped)

22:10.500 --> 22:13.000 line:90%
Kept line one

23:00.000 --> 23:02.000
Kept line two
`

func TestShiftVTT(t *testing.T) {
	out := string(ShiftVTT([]byte(sampleVTT), 1326)) // shift by 22:06

	if !strings.HasPrefix(out, "WEBVTT") {
		t.Fatalf("missing WEBVTT header:\n%s", out)
	}
	if strings.Contains(out, "UNE SÉRIE NETFLIX") || strings.Contains(out, "Intro dialogue") {
		t.Errorf("cues before the window should have been dropped:\n%s", out)
	}
	if !strings.Contains(out, "Kept line one") || !strings.Contains(out, "Kept line two") {
		t.Errorf("kept cues are missing:\n%s", out)
	}
	// 22:10.500 - 22:06.000 = 00:04.500
	if !strings.Contains(out, "00:00:04.500 --> 00:00:07.000") {
		t.Errorf("first kept cue not rebased correctly:\n%s", out)
	}
	if !strings.Contains(out, "line:90%") {
		t.Errorf("cue settings lost:\n%s", out)
	}
	t.Logf("shifted output:\n%s", out)
}

// TestParseVTTTimeFormats guards both timestamp shapes.
func TestParseVTTTimeFormats(t *testing.T) {
	cases := map[string]int{
		"00:03.717":    3717,
		"01:03.526":    63526,
		"22:10.500":    1330500,
		"01:22:10.500": 4930500,
	}
	for in, want := range cases {
		if got := parseVTTTime(in); got != want {
			t.Errorf("parseVTTTime(%q) = %d, want %d", in, got, want)
		}
	}
}
