package streaming

import (
	"math"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The five tiers that shipped before the ladder existed must keep their exact
// numbers. Clients already installed send these strings, and a tier that
// silently changed bitrate under them would be a regression delivered as an
// update.
func TestLegacyTiersAreUnchanged(t *testing.T) {
	for key, want := range map[string]qualityPreset{
		"360p":  {W: 640, H: 360, VideoBitrate: "1M", AudioBitrate: "128k"},
		"480p":  {W: 854, H: 480, VideoBitrate: "1800k", AudioBitrate: "128k"},
		"720p":  {W: 1280, H: 720, VideoBitrate: "3500k", AudioBitrate: "160k"},
		"1080p": {W: 1920, H: 1080, VideoBitrate: "6M", AudioBitrate: "160k"},
		"2160p": {W: 3840, H: 2160, VideoBitrate: "12M", AudioBitrate: "192k", EncoderPreset: "ultrafast"},
	} {
		got := presetFor(key)
		if got != want {
			t.Errorf("preset %q = %+v, want %+v", key, got, want)
		}
	}
}

// An unknown label still has to produce a stream rather than an error, and 720p
// is the tier that behaviour has always fallen back to.
func TestUnknownTierFallsBackTo720p(t *testing.T) {
	if got := presetFor("no-such-tier"); got != presetFor("720p") {
		t.Errorf("unknown tier = %+v, want the 720p preset", got)
	}
}

// Every rung the menu offers must be one the encoder can actually build.
func TestEveryLadderKeyResolves(t *testing.T) {
	for _, tier := range QualityLadderFor(0) {
		preset, ok := qualityPresets[tier.Key]
		if !ok {
			t.Errorf("tier %q is offered but has no preset", tier.Key)
			continue
		}
		if preset.W == 0 || preset.H == 0 || preset.VideoBitrate == "" {
			t.Errorf("tier %q has an incomplete preset: %+v", tier.Key, preset)
		}
	}
}

// The menu is a ladder against a connection, so each rung must ask less of the
// line than the one above it.
func TestLadderDescendsByBitrate(t *testing.T) {
	for _, height := range []int{0, 2160, 1080, 720, 480} {
		tiers := QualityLadderFor(height)
		for i := 1; i < len(tiers); i++ {
			if tiers[i].BitrateBps > tiers[i-1].BitrateBps {
				t.Errorf("source %dp: %q (%d bps) sits below %q (%d bps)",
					height, tiers[i].Key, tiers[i].BitrateBps,
					tiers[i-1].Key, tiers[i-1].BitrateBps)
			}
		}
	}
}

// A label that promises a bitrate the encoder is not given would be worse than
// no label at all: the whole point is choosing against a known number.
func TestLabelsMatchTheirBitrate(t *testing.T) {
	stated := regexp.MustCompile(`([0-9]+(?:,[0-9]+)?)\s*(k|M)bit/s`)
	for _, tier := range QualityLadderFor(0) {
		match := stated.FindStringSubmatch(tier.Label)
		if match == nil {
			t.Errorf("tier %q has no bitrate in its label %q", tier.Key, tier.Label)
			continue
		}
		promised, err := strconv.ParseFloat(strings.Replace(match[1], ",", ".", 1), 64)
		if err != nil {
			t.Errorf("tier %q: unreadable label %q", tier.Key, tier.Label)
			continue
		}
		if match[2] == "k" {
			promised /= 1000
		}
		// The label states the video bitrate; the audio track rides on top, so
		// the total is allowed to exceed it by the audio budget and no more.
		video := float64(parseBitrate(qualityPresets[tier.Key].VideoBitrate)) / 1e6
		if math.Abs(video-promised) > 0.01 {
			t.Errorf("tier %q promises %.2f Mbit/s but encodes at %.2f", tier.Key, promised, video)
		}
		if tier.BitrateBps <= parseBitrate(qualityPresets[tier.Key].VideoBitrate) {
			t.Errorf("tier %q: total bitrate %d does not include audio", tier.Key, tier.BitrateBps)
		}
	}
}

// Offering 4K for a 1080p source is offering an upscale: more bitrate spent on
// invented pixels, and a rescale on the server that forbids repackaging.
func TestLadderNeverOffersAnUpscale(t *testing.T) {
	for _, source := range []int{2160, 1080, 720, 480} {
		for _, tier := range QualityLadderFor(source) {
			if tier.Height > nativeTierHeight(source) {
				t.Errorf("source %dp is offered %q (%dp)", source, tier.Key, tier.Height)
			}
		}
	}
}

// Real files are rarely exactly 1080 lines. A 2.39:1 film stored without
// letterboxing is 1920x804, and capping it at 720p would be arithmetic beating
// the evidence.
func TestScopeFilmStillGetsItsNativeTier(t *testing.T) {
	offered := map[string]bool{}
	for _, tier := range QualityLadderFor(804) {
		offered[tier.Key] = true
	}
	if !offered["1080p"] {
		t.Error("a 1920x804 scope master was denied its 1080p tier")
	}
	if offered["2160p"] {
		t.Error("a 1920x804 master was offered 4K")
	}
}

// An unknown source height must not hide tiers that would have worked.
func TestUnknownHeightOffersEverything(t *testing.T) {
	if len(QualityLadderFor(0)) != len(qualityLadder) {
		t.Errorf("unknown height offers %d tiers, want all %d",
			len(QualityLadderFor(0)), len(qualityLadder))
	}
}

// A source below the smallest rung still has to be transcodable.
func TestTinySourceStillGetsARung(t *testing.T) {
	tiers := QualityLadderFor(120)
	if len(tiers) == 0 {
		t.Fatal("a 120-line source was offered no way to transcode at all")
	}
}

// EstimateBandwidth feeds the master playlist's BANDWIDTH attribute, which is
// what a player uses to decide it cannot keep up. It must agree with the menu.
func TestEstimateBandwidthAgreesWithTheLadder(t *testing.T) {
	for _, tier := range QualityLadderFor(0) {
		if got := EstimateBandwidth(tier.Key); got != tier.BitrateBps {
			t.Errorf("tier %q: playlist advertises %d bps, menu shows %d", tier.Key, got, tier.BitrateBps)
		}
	}
}

// The label is one string so that a bitrate is written in exactly one place,
// and the menus split it on this separator to lay the two halves out. A rung
// that dropped it would render as one long line rather than break.
func TestLabelsCarryTheMenuSeparator(t *testing.T) {
	for _, tier := range QualityLadderFor(0) {
		if strings.Count(tier.Label, " · ") != 1 {
			t.Errorf("tier %q label %q must hold exactly one \" · \" separator", tier.Key, tier.Label)
		}
	}
}

// Both dimensions reach the client: a menu that describes a rung as a picture
// size cannot invent the width from the height.
func TestTiersCarryTheirPictureSize(t *testing.T) {
	for _, tier := range QualityLadderFor(0) {
		preset := qualityPresets[tier.Key]
		if tier.Width != preset.W || tier.Height != preset.H {
			t.Errorf("tier %q advertises %dx%d, encodes %dx%d",
				tier.Key, tier.Width, tier.Height, preset.W, preset.H)
		}
	}
}
