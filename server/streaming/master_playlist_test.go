package streaming

import (
	"strings"
	"testing"
)

// The master FFmpeg writes for an audio rendition group declares each audio
// track twice, and the standalone copies carry the lowest BANDWIDTH in the
// file. An adaptive player picks by bandwidth, so it lands on a stream with no
// video — which is how publishing audio renditions broke playback even though
// ffprobe (which only reports the first program) looked correct.
const ffmpegMaster = `#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=YES,LANGUAGE="fra",CHANNELS="2",URI="stream_1.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_2",DEFAULT=YES,LANGUAGE="eng",CHANNELS="2",URI="stream_2.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2787664,AVERAGE-BANDWIDTH=2545520,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="group_aud"
stream_0.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=154857,AVERAGE-BANDWIDTH=112010,CODECS="mp4a.40.2",AUDIO="group_aud"
stream_1.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=126565,AVERAGE-BANDWIDTH=106550,CODECS="mp4a.40.2",AUDIO="group_aud"
stream_2.m3u8
`

func countPrefix(s, prefix string) int {
	n := 0
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}

func TestFilterMasterPlaylist_LeavesOnlyTheVideoVariant(t *testing.T) {
	got := filterMasterPlaylist(ffmpegMaster)

	if n := countPrefix(got, "#EXT-X-STREAM-INF"); n != 1 {
		t.Fatalf("expected exactly 1 playable variant, got %d\n%s", n, got)
	}
	if !strings.Contains(got, "RESOLUTION=1280x720") {
		t.Error("the video variant must survive")
	}
	// The audio tracks stay reachable — as group members, which is the correct
	// way to expose them. Dropping these would cost the instant language switch.
	if n := countPrefix(got, "#EXT-X-MEDIA"); n != 2 {
		t.Errorf("expected both audio renditions to remain declared, got %d", n)
	}
	if !strings.Contains(got, `URI="stream_1.m3u8"`) ||
		!strings.Contains(got, `URI="stream_2.m3u8"`) {
		t.Error("audio rendition URIs must remain reachable")
	}
	// The URI lines belonging to the removed variants must go with them,
	// otherwise they read as a bare playlist entry.
	for _, line := range strings.Split(got, "\n") {
		if strings.TrimSpace(line) == "stream_1.m3u8" ||
			strings.TrimSpace(line) == "stream_2.m3u8" {
			t.Errorf("orphaned URI line left behind: %q", line)
		}
	}
	if !strings.HasPrefix(got, "#EXTM3U") {
		t.Error("playlist header must be preserved")
	}
}

func TestFilterMasterPlaylist_AudioOnlyMediaIsLeftAlone(t *testing.T) {
	// No variant carries RESOLUTION, so filtering would empty the master.
	// Better to serve FFmpeg's version untouched than nothing at all.
	audioOnly := `#EXTM3U
#EXT-X-VERSION:6
#EXT-X-STREAM-INF:BANDWIDTH=154857,CODECS="mp4a.40.2"
stream_0.m3u8
`
	if got := filterMasterPlaylist(audioOnly); got != audioOnly {
		t.Errorf("audio-only master must pass through unchanged, got:\n%s", got)
	}
}

func TestFilterMasterPlaylist_SingleVariantUnchanged(t *testing.T) {
	// The pre-A1 shape: one muxed variant, nothing to strip.
	single := `#EXTM3U
#EXT-X-VERSION:6
#EXT-X-STREAM-INF:BANDWIDTH=2787664,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
stream_0.m3u8
`
	if got := filterMasterPlaylist(single); got != single {
		t.Errorf("a master with only a video variant must be untouched, got:\n%s", got)
	}
}
