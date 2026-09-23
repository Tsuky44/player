package streaming

import "sort"

// The transcoding ladder.
//
// A tier is a resolution *and* a bitrate. Offering only one bitrate per
// resolution is what leaves a viewer stuck: the picture stalls at 1080p and the
// only way down is 720p, which throws away half the lines to solve a problem
// that was never about lines. The menu is a ladder for that reason, and the
// bitrate is written next to each rung so the choice can be made against a known
// link speed rather than by trial and error.
//
// The five tiers that existed before — 360p, 480p, 720p, 1080p, 2160p — keep
// their exact keys and their exact numbers. Clients already installed send those
// strings, and a tier that silently changed bitrate under them would be a
// regression delivered as an update.

// QualityTier is one rung: what the client shows, and what it asks for.
type QualityTier struct {
	// Key is what the client sends back as ?quality=, and is stable forever.
	Key string `json:"key"`
	// Label is the menu entry, e.g. "1080p · 6 Mbit/s".
	Label string `json:"label"`
	// Width and Height are the tier's picture size. Height caps the menu at the
	// source; both are shown by the menus that describe a rung rather than just
	// name it.
	Width  int `json:"width"`
	Height int `json:"height"`
	// BitrateBps is video plus audio: what the link actually has to carry, and
	// the number the label states.
	BitrateBps int `json:"bitrate_bps"`

	preset qualityPreset
}

// qualityLadder is ordered from the most demanding rung to the least, which is
// the order the menu shows and the order a fallback walks.
//
// The bitrates are deliberately not a smooth curve. They cluster where real
// links sit: around 20 and 10 for a good fibre upload, 6 and 4 for an ordinary
// one, 2 and 1 for a phone on mobile data or a saturated upstream.
var qualityLadder = []QualityTier{
	{Key: "2160p-40m", Label: "4K · 40 Mbit/s", preset: uhd("40M", "192k")},
	{Key: "2160p-20m", Label: "4K · 20 Mbit/s", preset: uhd("20M", "192k")},
	// The original 4K tier. See the note on ultrafast in uhd().
	{Key: "2160p", Label: "4K · 12 Mbit/s", preset: uhd("12M", "192k")},

	{Key: "1080p-20m", Label: "1080p · 20 Mbit/s", preset: hd1080("20M", "192k")},
	{Key: "1080p-10m", Label: "1080p · 10 Mbit/s", preset: hd1080("10M", "160k")},
	{Key: "1080p", Label: "1080p · 6 Mbit/s", preset: hd1080("6M", "160k")},
	{Key: "1080p-4m", Label: "1080p · 4 Mbit/s", preset: hd1080("4M", "160k")},
	{Key: "1080p-2m", Label: "1080p · 2 Mbit/s", preset: hd1080("2M", "128k")},

	{Key: "720p-6m", Label: "720p · 6 Mbit/s", preset: hd720("6M", "160k")},
	{Key: "720p", Label: "720p · 3,5 Mbit/s", preset: hd720("3500k", "160k")},
	{Key: "720p-2m", Label: "720p · 2 Mbit/s", preset: hd720("2M", "128k")},
	{Key: "720p-1m", Label: "720p · 1 Mbit/s", preset: hd720("1M", "96k")},

	{Key: "480p", Label: "480p · 1,8 Mbit/s", preset: sd480("1800k", "128k")},
	{Key: "480p-720k", Label: "480p · 720 kbit/s", preset: sd480("720k", "96k")},

	{Key: "360p", Label: "360p · 1 Mbit/s", preset: sd360("1M", "128k")},
	{Key: "360p-420k", Label: "360p · 420 kbit/s", preset: sd360("420k", "64k")},
}

// uhd builds a 2160p rung.
//
// EncoderPreset is forced to "ultrafast" at this resolution, unlike every other
// tier. Measured on the same 4K source, same CRF: veryfast completes 30s of
// content in 23.1s (1.30x real-time) vs ultrafast's 8.5s (3.55x). 1.30x looks
// fine until you subtract the decode cost of a real 10-bit HEVC source and the
// weaker per-core throughput of an older CPU-only Xeon — at which point it
// measures out below 1.0x, and a below-1.0x encoder can never refill a buffer it
// has already fallen behind on. That is exactly the failure mode a cold-started
// session hits right after a seek: no buffer cushion, so it has to be faster
// than real-time from frame one or it stalls forever. veryfast's extra ~2.4x
// bitrate cost at equal CRF (measured on 1080p) is already absorbed by the VBV
// cap, so ultrafast's lower quality-per-bit here mostly shows up as "closer to
// the bitrate ceiling more often", not as a broken stream.
func uhd(video, audio string) qualityPreset {
	return qualityPreset{W: 3840, H: 2160, VideoBitrate: video, AudioBitrate: audio, EncoderPreset: "ultrafast"}
}

func hd1080(video, audio string) qualityPreset {
	return qualityPreset{W: 1920, H: 1080, VideoBitrate: video, AudioBitrate: audio}
}

func hd720(video, audio string) qualityPreset {
	return qualityPreset{W: 1280, H: 720, VideoBitrate: video, AudioBitrate: audio}
}

func sd480(video, audio string) qualityPreset {
	return qualityPreset{W: 854, H: 480, VideoBitrate: video, AudioBitrate: audio}
}

func sd360(video, audio string) qualityPreset {
	return qualityPreset{W: 640, H: 360, VideoBitrate: video, AudioBitrate: audio}
}

// qualityPresets is the lookup the encoder uses, derived from the ladder so the
// two cannot drift apart.
var qualityPresets = buildQualityPresets()

func buildQualityPresets() map[string]qualityPreset {
	presets := make(map[string]qualityPreset, len(qualityLadder))
	for _, tier := range qualityLadder {
		presets[tier.Key] = tier.preset
	}
	return presets
}

// QualityLadderFor is the menu for one file: every rung the server offers, minus
// the ones above what the file actually contains, ordered by what it costs the
// link.
//
// Sorting on bitrate rather than on resolution is the point of the whole ladder.
// The viewer is choosing against a connection, so "the next one down" has to
// mean "asks less of the line" — a menu where 360p sits below a 480p rung that
// costs less would be lying about which way is cheaper. Where two rungs cost the
// same, the taller picture comes first: same price, more lines.
//
// Offering 4K for a 1080p source is offering an upscale — more bitrate spent on
// invented pixels, and on the server a rescale that forbids repackaging. A
// source whose height is unknown gets the whole ladder, since guessing downward
// would hide tiers that work.
func QualityLadderFor(sourceHeight int) []QualityTier {
	tiers := make([]QualityTier, 0, len(qualityLadder))
	for _, tier := range qualityLadder {
		if sourceHeight > 0 && tier.preset.H > nativeTierHeight(sourceHeight) {
			continue
		}
		tier.Width = tier.preset.W
		tier.Height = tier.preset.H
		tier.BitrateBps = tier.bitrateBps()
		tiers = append(tiers, tier)
	}
	sort.SliceStable(tiers, func(i, j int) bool {
		if tiers[i].BitrateBps != tiers[j].BitrateBps {
			return tiers[i].BitrateBps > tiers[j].BitrateBps
		}
		return tiers[i].Height > tiers[j].Height
	})

	return tiers
}

// nativeTierHeight is the tallest rung a source of this height earns.
//
// The thresholds sit below each nominal height on purpose, and are the same ones
// the client picks its opening tier with (qualityForSourceHeight in
// web_quality.dart). Real files are rarely exactly 1080 or 2160 lines: a 2.39:1
// film stored without letterboxing is 1920x804, and anamorphic or slightly
// cropped masters land a few dozen lines short. All of those are the tier they
// belong to, not the one below.
//
// Keeping the two in step matters: the client picks the opening tier from these
// thresholds, and a server that then refused to offer it would leave the menu
// disagreeing with what is already playing.
func nativeTierHeight(sourceHeight int) int {
	switch {
	case sourceHeight > 1400:
		return 2160
	case sourceHeight > 800:
		return 1080
	case sourceHeight > 560:
		return 720
	case sourceHeight > 400:
		return 480
	default:
		return 360
	}
}

// bitrateBps is what the label promises: video plus audio. It reads the same
// two fields the encoder is handed, so the number in the menu cannot describe a
// stream the server does not produce.
func (t QualityTier) bitrateBps() int {
	return parseBitrate(t.preset.VideoBitrate) + parseBitrate(t.preset.AudioBitrate)
}
