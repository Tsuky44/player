package streaming

import "testing"

func TestParseVideoSegmentIndex_ReadsBothContainers(t *testing.T) {
	// This feeds the JIT throttle. Failing to read an index the session does
	// produce silently disables the throttle and transcodes the whole film, so
	// both extensions are accepted regardless of what this session writes.
	cases := map[string]struct {
		want int
		ok   bool
	}{
		"stream_0_000.ts":  {0, true},
		"stream_0_007.ts":  {7, true},
		"stream_0_000.m4s": {0, true},
		"stream_0_142.m4s": {142, true},
		// Audio renditions are not what the throttle counts.
		"stream_1_000.ts": {0, false},
		// Everything else the session serves.
		"stream_0.m3u8": {0, false},
		"init_0.mp4":    {0, false},
		"master.m3u8":   {0, false},
		"stream_0_.ts":  {0, false},
		"stream_0_x.ts": {0, false},
	}
	for name, want := range cases {
		got, ok := parseVideoSegmentIndex(name)
		if ok != want.ok || (ok && got != want.want) {
			t.Errorf("parseVideoSegmentIndex(%q) = %d,%v — want %d,%v",
				name, got, ok, want.want, want.ok)
		}
	}
}

func TestIsPendingSessionFile_CoversEverythingTheMuxerWritesLate(t *testing.T) {
	// Answering 404 for one of these is fatal to an HLS demuxer, and the fMP4
	// initialisation segment is the one this list gained: a player fetches it
	// the moment it has read the child playlist that names it, which can be
	// before FFmpeg has flushed it.
	for _, ext := range []string{".ts", ".m4s", ".mp4", ".m3u8"} {
		if !isPendingSessionFile(ext) {
			t.Errorf("%s must be waited on, not 404'd", ext)
		}
	}
	for _, ext := range []string{".vtt", ".txt", "", ".exe"} {
		if isPendingSessionFile(ext) {
			t.Errorf("%s must not hold a request open", ext)
		}
	}
}

func TestSegmentExt_FollowsTheContainer(t *testing.T) {
	if got := ContainerFMP4.SegmentExt(); got != ".m4s" {
		t.Errorf("fMP4 segment ext = %q", got)
	}
	if got := ContainerTS.SegmentExt(); got != ".ts" {
		t.Errorf("TS segment ext = %q", got)
	}
	// A session created before the field existed still counts .ts segments.
	s := &TranscodeSession{}
	if got := s.segmentExt(); got != ".ts" {
		t.Errorf("a session with no declared container = %q, want .ts", got)
	}
}
