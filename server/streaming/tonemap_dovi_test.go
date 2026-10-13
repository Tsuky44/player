package streaming

import (
	"encoding/json"
	"strings"
	"testing"
)

func doviProfile5Probe() *ProbeResult {
	return &ProbeResult{Video: &VideoStreamInfo{
		Width: 3840, Height: 2160, Codec: "hevc", PixFmt: "yuv420p10le",
		BitDepth: 10, ColorTransfer: "smpte2084", FrameRate: 24, DoviProfile: 5,
	}}
}

func TestToneMapper_DolbyVisionProfile5GoesThroughTheRPU(t *testing.T) {
	setFilterSetForTest("zscale", "tonemap", "scale", "libplacebo")
	setLibplaceboForTest(true)
	t.Cleanup(func() { setLibplaceboForTest(false) })

	// zscale lit la couche de base IPTPQc2 comme du YCbCr BT.2020 : rose et
	// vert. Seul libplacebo applique la RPU.
	args := BuildFFmpegArgs(TranscodeOptions{
		InputPath: "/x.mkv", Quality: "1080p", TmpDir: "/tmp/x", SegmentDuration: 2,
		Probe: doviProfile5Probe(),
		Video: VideoPlan{Tonemap: true},
	})
	chain, _ := argValue(args, "-vf")
	if !strings.Contains(chain, "libplacebo=") || strings.Contains(chain, "zscale") {
		t.Errorf("profile 5 must be tone mapped by libplacebo alone: %q", chain)
	}
	if strings.Index(chain, "scale=w=1920") > strings.Index(chain, "libplacebo=") {
		t.Errorf("scaling must come before tone mapping: %q", chain)
	}
	// Sans périphérique explicite, libplacebo refuse le Vulkan logiciel.
	if v, _ := argValue(args, "-init_hw_device"); v != "vulkan" {
		t.Errorf("-init_hw_device = %q, want vulkan", v)
	}
	if hasArg(args, "-hwaccel") {
		t.Error("hwaccel auto would try to decode on the software Vulkan device")
	}
	if got, _ := argValue(args, "-colorspace"); got != "bt709" {
		t.Errorf("-colorspace = %q, want bt709", got)
	}

	// Un profil 8.1 a une couche de base HDR10 : la chaîne ordinaire suffit.
	p81 := doviProfile5Probe()
	p81.Video.DoviProfile, p81.Video.DoviBLCompatID = 8, 1
	if tm := toneMapperFor(p81.Video); tm.Vulkan || !strings.Contains(tm.Filter, "zscale") {
		t.Errorf("profile 8.1 = %+v, want the zscale chain", tm)
	}
}

func TestToneMapper_Profile5FallsBackToZscaleWithoutVulkan(t *testing.T) {
	setFilterSetForTest("zscale", "tonemap", "scale", "libplacebo")
	setLibplaceboForTest(false)

	// Une image aux couleurs fausses vaut mieux qu'une session morte sur un
	// filtre qui ne s'initialise pas.
	tm := toneMapperFor(doviProfile5Probe().Video)
	if tm.Vulkan || !strings.Contains(tm.Filter, "zscale") {
		t.Errorf("without a Vulkan device = %+v, want the zscale chain", tm)
	}
}

func TestPreviewArgs_DolbyVisionProfile5OpensAVulkanDevice(t *testing.T) {
	args := strings.Join(previewArgs("/m/film.mkv", 120,
		ToneMapper{Filter: doviToSDRFilter, Vulkan: true}, true, 1), " ")
	if !strings.Contains(args, "-init_hw_device vulkan") {
		t.Errorf("args %q must open a Vulkan device", args)
	}
	if scale, tm := strings.Index(args, "scale=480"), strings.Index(args, "libplacebo="); scale < 0 || tm < scale {
		t.Errorf("tone mapping must follow the scale: %q", args)
	}
}

func TestVideoStreamInfo_TellsTheClientWhenDirectPlayNeedsDolbyVision(t *testing.T) {
	for profile, want := range map[int]bool{0: false, 5: true, 7: false, 8: false} {
		raw, err := json.Marshal(VideoStreamInfo{DoviProfile: profile})
		if err != nil {
			t.Fatal(err)
		}
		var got struct {
			Needs bool `json:"needs_dolby_vision"`
		}
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatal(err)
		}
		if got.Needs != want {
			t.Errorf("profile %d: needs_dolby_vision = %v, want %v", profile, got.Needs, want)
		}
	}
}
