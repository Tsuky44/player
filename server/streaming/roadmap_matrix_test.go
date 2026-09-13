package streaming

import "testing"

// Capability contracts, not guesses based on the OS name. Android and browsers
// must still probe their real decoder/display/output before declaring these.
func TestRoadmapPlaybackMatrix(t *testing.T) {
	full := Capabilities{
		Container:        ContainerFMP4,
		VideoCodecs:      map[string]bool{"h264": true, "hevc": true, "av1": true},
		AudioCodecs:      map[string]bool{"aac": true, "ac3": true, "eac3": true, "truehd": true, "dts": true},
		MaxAudioChannels: 8, MaxVideoBitDepth: 10, HDR: true,
	}
	dv := full
	dv.DolbyVision = true
	clients := []struct {
		name string
		caps Capabilities
	}{
		{"mpv-texture", full}, {"mpv-native-dv", dv},
		{"android-hdr-surround", full}, {"android-dv-surround", dv},
		{"web-legacy", LegacyCapabilities()},
	}
	videos := []struct {
		name, codec, pix, transfer string
		depth, dovi                int
	}{
		{"h264-sdr", "h264", "yuv420p", "bt709", 8, 0},
		{"hevc-hdr10", "hevc", "yuv420p10le", "smpte2084", 10, 0},
		{"dv5", "hevc", "yuv420p10le", "smpte2084", 10, 5},
		{"dv8", "hevc", "yuv420p10le", "smpte2084", 10, 8},
		{"av1-sdr", "av1", "yuv420p", "bt709", 8, 0},
	}
	for _, client := range clients {
		for _, video := range videos {
			t.Run(client.name+"/"+video.name, func(t *testing.T) {
				probe := &ProbeResult{Video: &VideoStreamInfo{
					Codec: video.codec, Width: 1920, Height: 1080,
					PixFmt: video.pix, BitDepth: video.depth,
					ColorTransfer: video.transfer, DoviProfile: video.dovi,
				}}
				wantCopy := client.name != "web-legacy" || video.name == "h264-sdr"
				if video.dovi == 5 && !client.caps.DolbyVision {
					wantCopy = false
				}
				got := PlanVideo(probe, "1080p", false, 8_000_000, 12_000_000, client.caps)
				if got.Copy != wantCopy {
					t.Fatalf("plan = %+v; want copy=%v", got, wantCopy)
				}
				if !got.Copy && got.Reason == "" {
					t.Fatal("transcode must explain its reason")
				}
				if got.Tonemap != (!wantCopy && video.depth == 10) {
					t.Fatalf("unexpected tone mapping: %+v", got)
				}
				// Bitmap subtitles and a lower quality must override even a capable client.
				for _, forced := range []VideoPlan{
					PlanVideo(probe, "1080p", true, 8_000_000, 12_000_000, client.caps),
					PlanVideo(probe, "720p", false, 8_000_000, 12_000_000, client.caps),
					PlanVideo(probe, "1080p", false, 20_000_000, 12_000_000, client.caps),
				} {
					if forced.Copy || forced.Reason == "" {
						t.Fatalf("unsafe forced plan: %+v", forced)
					}
				}
			})
		}
		for _, codec := range []string{"aac", "ac3", "eac3", "truehd", "dts"} {
			t.Run(client.name+"/audio-"+codec, func(t *testing.T) {
				channels := 6
				if codec == "aac" {
					channels = 2
				}
				probe := &ProbeResult{Audio: []AudioStreamInfo{{Codec: codec, Channels: channels}}}
				got := PlanAudio(probe, 0, client.caps, presetFor("1080p"))
				// TrueHD/DTS cannot be copied into the HLS containers, even when
				// the same decoder can open them directly from the source file.
				wantCopy := codec == "aac" || (client.name != "web-legacy" && (codec == "ac3" || codec == "eac3"))
				if got.Copy != wantCopy {
					t.Fatalf("audio = %+v; want copy=%v", got, wantCopy)
				}
				wantChannels := channels
				if client.name == "web-legacy" {
					wantChannels = 2
				}
				if got.Channels != wantChannels {
					t.Fatalf("audio = %+v; want %d channels", got, wantChannels)
				}
			})
		}
	}
}
