package streaming

import (
	"strconv"
	"strings"
	"testing"
)

func countPrefix(s, prefix string) int {
	n := 0
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}

func threeLanguageProbe() *ProbeResult {
	return &ProbeResult{
		Video: &VideoStreamInfo{Width: 1920, Height: 1080, FrameRate: 24, Codec: "h264", PixFmt: "yuv420p"},
		Audio: []AudioStreamInfo{
			{TypedIndex: 0, Codec: "aac", Channels: 2, Language: "jpn", Title: "Japonais"},
			{TypedIndex: 1, Codec: "dts", Channels: 6, Language: "fra"},
			{TypedIndex: 2, Codec: "ac3", Channels: 6, Language: "eng"},
		},
	}
}

// Every line that is not a comment is a URI, so a tag that fails to be written
// silently turns into one. That is exactly how FFmpeg's own master breaks (no
// BANDWIDTH, no tag, a line starting with a comma), and it is the single
// property the whole file has to guarantee.
func TestBuildMasterPlaylist_EveryTagLineIsWellFormed(t *testing.T) {
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:                  threeLanguageProbe(),
		Quality:                "1080p",
		AudioTypedIndexes:      []int{0, 1, 2},
		DefaultAudioTypedIndex: 1,
		BandwidthBps:           4_200_000,
	})

	uris := []string{}
	for _, line := range strings.Split(got, "\n") {
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if !strings.HasPrefix(line, "#EXT") {
				t.Errorf("unknown tag line: %q", line)
			}
			continue
		}
		uris = append(uris, line)
	}
	// The audio renditions are reached through their URI attribute, so the only
	// bare URI in the file is the video variant's.
	if len(uris) != 1 || uris[0] != "stream_0.m3u8" {
		t.Errorf("expected exactly one URI line (the video variant), got %v", uris)
	}
	if !strings.HasPrefix(got, "#EXTM3U\n") {
		t.Error("playlist must open with #EXTM3U")
	}
	if !strings.Contains(got, "#EXT-X-STREAM-INF:BANDWIDTH=4200000,") {
		t.Errorf("BANDWIDTH must be present and first on the variant line:\n%s", got)
	}
	if !strings.Contains(got, "RESOLUTION=1920x1080") {
		t.Errorf("variant must advertise its resolution:\n%s", got)
	}
}

// A group may name one default. FFmpeg marks them all, and a player handed
// several takes the first — which discards the ?audio=N the session was started
// for, the only way the web client can pick a language at all.
func TestBuildMasterPlaylist_ExactlyOneDefaultAndItIsTheRequestedTrack(t *testing.T) {
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:                  threeLanguageProbe(),
		Quality:                "1080p",
		AudioTypedIndexes:      []int{0, 1, 2},
		DefaultAudioTypedIndex: 2,
	})

	if n := strings.Count(got, "DEFAULT=YES"); n != 1 {
		t.Fatalf("expected exactly 1 default rendition, got %d\n%s", n, got)
	}
	for _, line := range strings.Split(got, "\n") {
		if !strings.Contains(line, "DEFAULT=YES") {
			continue
		}
		if !strings.Contains(line, `URI="stream_3.m3u8"`) {
			t.Errorf("the requested track (source 2 = rendition 2 = stream_3) must be the default, got %q", line)
		}
		if !strings.Contains(line, `LANGUAGE="eng"`) {
			t.Errorf("default rendition lost its language: %q", line)
		}
	}
}

// Renditions are numbered from the video variant: source track k is stream k+1,
// matching what -var_stream_map lays out. Getting this off by one points every
// language at its neighbour's playlist.
func TestBuildMasterPlaylist_RenditionURIsFollowVarStreamMap(t *testing.T) {
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:             threeLanguageProbe(),
		Quality:           "1080p",
		AudioTypedIndexes: []int{0, 1, 2},
	})

	if n := countPrefix(got, "#EXT-X-MEDIA"); n != 3 {
		t.Fatalf("expected 3 audio renditions, got %d\n%s", n, got)
	}
	for _, want := range []string{`URI="stream_1.m3u8"`, `URI="stream_2.m3u8"`, `URI="stream_3.m3u8"`} {
		if !strings.Contains(got, want) {
			t.Errorf("missing rendition %s\n%s", want, got)
		}
	}
	if strings.Contains(got, `URI="stream_0.m3u8"`) {
		t.Error("stream_0 is the video variant, never an audio rendition")
	}
}

// A rendition group only exists when there are renditions: a master that points
// a variant at an AUDIO group it never declares is broken outright.
func TestBuildMasterPlaylist_NoAudioMeansNoGroup(t *testing.T) {
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:   &ProbeResult{Video: &VideoStreamInfo{Width: 1280, Height: 720}},
		Quality: "720p",
	})

	if strings.Contains(got, "#EXT-X-MEDIA") {
		t.Errorf("no audio tracks, so no renditions may be declared:\n%s", got)
	}
	if strings.Contains(got, "AUDIO=") {
		t.Errorf("variant must not reference a group that does not exist:\n%s", got)
	}
	if !strings.Contains(got, "RESOLUTION=1280x720") {
		t.Errorf("video variant is still expected:\n%s", got)
	}
}

// Track titles are arbitrary text out of the container. A quote in one would
// close the attribute early and corrupt every tag that follows it on the line.
func TestBuildMasterPlaylist_HostileTrackTitleCannotBreakTheLine(t *testing.T) {
	probe := &ProbeResult{
		Video: &VideoStreamInfo{Width: 1280, Height: 720},
		Audio: []AudioStreamInfo{
			{TypedIndex: 0, Title: `VF "true" 5.1, remux` + "\nURI=\"evil.m3u8\"", Language: "fra"},
		},
	}
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:             probe,
		Quality:           "720p",
		AudioTypedIndexes: []int{0},
	})

	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	// #EXTM3U, version, independent-segments, the rendition, the variant, its URI.
	if len(lines) != 6 {
		t.Fatalf("expected 6 lines, the title smuggled in %d:\n%s", len(lines), got)
	}
	if n := countPrefix(got, "#EXT-X-MEDIA"); n != 1 {
		t.Fatalf("expected 1 rendition line, got %d\n%s", n, got)
	}
	// URI is written last, so the real one has to terminate the line: nothing the
	// title contains can append an attribute after it.
	if !strings.HasSuffix(lines[3], `URI="stream_1.m3u8"`) {
		t.Errorf("rendition line must end on its own URI, got %q", lines[3])
	}
	// Quotes are what would end the attribute early. Exactly the delimiters
	// remain: GROUP-ID, NAME, LANGUAGE, CHANNELS and URI, two each.
	if n := strings.Count(lines[3], `"`); n != 10 {
		t.Errorf("expected 10 quote characters (5 attributes), got %d in %q", n, lines[3])
	}
}

// Bandwidth is mandatory to the format. A caller that cannot supply one still
// has to get a playable master, not a tagless line.
func TestBuildMasterPlaylist_BandwidthFallsBackToThePreset(t *testing.T) {
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:   &ProbeResult{Video: &VideoStreamInfo{Width: 1280, Height: 720}},
		Quality: "720p",
	})

	want := EstimateBandwidth("720p")
	if !strings.Contains(got, "BANDWIDTH=") {
		t.Fatalf("BANDWIDTH is mandatory:\n%s", got)
	}
	if !strings.Contains(got, "BANDWIDTH="+strconv.Itoa(want)) {
		t.Errorf("expected the 720p ceiling %d as fallback:\n%s", want, got)
	}
}

// A downscaled rendition must advertise the size it will actually publish, not
// the box it was fitted into.
func TestBuildMasterPlaylist_ResolutionReflectsTheScaledOutput(t *testing.T) {
	// A 2.39:1 4K scope master asked for 720p: 3840x1606 fits to 1280x534.
	probe := &ProbeResult{Video: &VideoStreamInfo{Width: 3840, Height: 1606}}
	got := BuildMasterPlaylist(MasterPlaylistOptions{
		Probe:             probe,
		Quality:           "720p",
		AudioTypedIndexes: nil,
	})

	if !strings.Contains(got, "RESOLUTION=1280x534") {
		t.Errorf("expected the fitted resolution, got:\n%s", got)
	}
}
