package streaming

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
	"sync"
)

// VideoPlan is what the session will do with the picture.
type VideoPlan struct {
	// Copy repackages the source frames instead of decoding and re-encoding
	// them. Roughly fifty times cheaper, and bit-identical to the source
	// instead of a generation down.
	Copy bool
	// Tonemap converts HDR to SDR on the encoding path. Without it an HDR
	// source re-encoded to BT.709 does not come out "as SDR" — it comes out
	// visibly wrong: PQ code values read as gamma, which is the washed-out,
	// grey, desaturated picture people describe as "the colours are dead".
	Tonemap bool
	// Reason names why the copy was refused, for the session log. A copy that
	// silently did not happen is the hardest kind of performance bug to notice.
	Reason string
}

// PlanVideo decides between repackaging the picture and re-encoding it.
//
// Every condition here is a way the copy would reach the viewer broken rather
// than merely suboptimal, so the answer defaults to no:
//
//   - a codec the client did not declare is the whole point of transcoding;
//   - a codec the segment container cannot hold makes FFmpeg refuse to write a
//     header and exit before its first segment, so /start times out and the
//     media never loads at all;
//   - a bit depth or chroma layout past what the client declared fails
//     *silently*, showing a black picture with no error;
//   - HDR sent to a client that cannot display it is the washed-out picture
//     above, arrived at from the other direction;
//   - copying bytes cannot resize them, so any scaling rules it out;
//   - burning a bitmap subtitle means painting on the frames, which means
//     decoding them;
//   - and the bitrate ceiling is the one non-technical limit: copying means
//     sending the file's own bitrate, so past a point the CPU saved is paid for
//     in stalling on the viewer's connection.
func PlanVideo(probe *ProbeResult, quality string, burn bool, sourceBitrateBps, ceilingBps int64, caps Capabilities) VideoPlan {
	if probe == nil || probe.Video == nil {
		return VideoPlan{Reason: "no video stream probed"}
	}
	v := probe.Video
	// The encoder only ever produces SDR, so an HDR source that is not copied
	// has to be tone mapped on the way through — whatever the reason it was not
	// copied.
	encodePlan := func(reason string) VideoPlan {
		return VideoPlan{Tonemap: v.IsHDR(), Reason: reason}
	}

	if burn {
		return encodePlan("bitmap subtitle burned in")
	}
	codec := canonicalVideoCodec(v.Codec)
	if codec == "" {
		return encodePlan(fmt.Sprintf("unknown source codec %q", v.Codec))
	}
	if !caps.DecodesVideo(codec) {
		return encodePlan("client does not decode " + codec)
	}
	if !caps.CanCarryVideo(codec) {
		return encodePlan(fmt.Sprintf("%s cannot be muxed into %s segments", codec, caps.Container))
	}
	if !v.Chroma420() {
		return encodePlan("chroma layout " + v.PixFmt + " is not 4:2:0")
	}
	if v.DepthOrDefault() > caps.MaxVideoBitDepth {
		return encodePlan(fmt.Sprintf("%d-bit source, client tops out at %d", v.DepthOrDefault(), caps.MaxVideoBitDepth))
	}
	if v.IsHDR() && !caps.HDR {
		return encodePlan(v.HDRFormat() + " source, client has no HDR display")
	}
	if needsDolbyVisionDecoder(v) && !caps.DolbyVision {
		return encodePlan("Dolby Vision profile 5 needs a Dolby Vision decoder")
	}
	if buildScaleFilter(probe, presetFor(quality)) != "" {
		return encodePlan("source is larger than the " + quality + " box")
	}
	if ceilingBps > 0 && sourceBitrateBps > ceilingBps {
		return encodePlan("source bitrate above the copy ceiling")
	}
	return VideoPlan{Copy: true}
}

// needsDolbyVisionDecoder reports a stream whose base layer is not viewable
// without Dolby Vision itself.
//
// Profiles 7, 8.1 and 8.4 carry a base layer that is ordinary HDR10 or HLG: a
// display without Dolby Vision shows them correctly, just without the dynamic
// metadata. Profile 5 does not — its base layer is in a private colour space
// (IPTPQc2), and anything that decodes it as HDR10 renders it green and washed
// out. That is the one profile that has to be refused rather than degraded.
func needsDolbyVisionDecoder(v *VideoStreamInfo) bool {
	return v.DoviProfile == 5
}

// AudioPlan is what the session will do with one audio track.
type AudioPlan struct {
	// Copy remuxes the source track untouched. This is what preserves Dolby
	// Digital Plus — Atmos included, since the object bed rides inside the
	// E-AC-3 stream and survives anything that does not decode it.
	Copy bool
	// Codec is the FFmpeg encoder name when Copy is false.
	Codec string
	// Channels is how many channels the output carries.
	Channels int
	// Bitrate is the encoder's target ("448k"), empty when copying.
	Bitrate string
	// Downmix applies the dialogue-forward mix levels of ADR-0005. Only ever
	// set when a multichannel source is being folded to stereo, which is the
	// only case those levels describe.
	Downmix bool
}

// maxAC3Channels is what FFmpeg's AC-3 and E-AC-3 encoders will accept.
//
// Both top out at 5.1. A 7.1 source encoded to either has to be folded to 5.1
// first, and asking for more makes the encoder fail at initialisation — which
// takes the whole session with it.
const maxAC3Channels = 6

// PlanAudio decides what happens to one source audio track.
//
// The order is "least damage first": remux what the client can already take,
// then keep the channels if it can carry them, and only fold to stereo when
// there is nothing else left. The old behaviour — always AAC, always two
// channels — is what this produces for a client that declares nothing, so
// nothing regresses.
func PlanAudio(probe *ProbeResult, typedIndex int, caps Capabilities, preset qualityPreset) AudioPlan {
	stereoFallback := AudioPlan{
		Codec:    "aac",
		Channels: 2,
		Bitrate:  preset.AudioBitrate,
	}
	if probe == nil || typedIndex < 0 || typedIndex >= len(probe.Audio) {
		return stereoFallback
	}
	a := probe.Audio[typedIndex]
	srcChannels := a.Channels
	if srcChannels <= 0 {
		return stereoFallback
	}
	stereoFallback.Downmix = srcChannels > 2

	codec := canonicalAudioCodec(a.Codec)
	// Remux when the client decodes it, the container holds it, and the client
	// can actually put those channels somewhere.
	if codec != "" &&
		caps.DecodesAudio(codec) &&
		caps.CanCarryAudio(codec) &&
		srcChannels <= caps.MaxAudioChannels {
		return AudioPlan{Copy: true, Channels: srcChannels}
	}

	// Re-encoding, then. How many channels may survive it?
	outChannels := srcChannels
	if outChannels > caps.MaxAudioChannels {
		outChannels = caps.MaxAudioChannels
	}
	if outChannels <= 2 {
		return stereoFallback
	}

	// Surround is worth keeping. E-AC-3 first: it is the most efficient of the
	// three at these channel counts, and it is the one a television can hand
	// straight to an amplifier as a bitstream instead of decoding itself.
	for _, candidate := range []string{"eac3", "ac3"} {
		if caps.DecodesAudio(candidate) && caps.CanCarryAudio(candidate) {
			ch := outChannels
			if ch > maxAC3Channels {
				ch = maxAC3Channels
			}
			return AudioPlan{
				Codec:    candidate,
				Channels: ch,
				Bitrate:  surroundBitrate(candidate, ch),
			}
		}
	}
	// Multichannel AAC as the last surround option: universally muxable, and
	// every client that declares more than two channels decodes it.
	return AudioPlan{
		Codec:    "aac",
		Channels: outChannels,
		Bitrate:  fmt.Sprintf("%dk", outChannels*64),
	}
}

// surroundBitrate is the target for a channel-based surround encode.
//
// The numbers are the broadcast-standard ones rather than anything derived:
// 448k is what a 5.1 AC-3 track on a disc is authored at, and E-AC-3 reaches
// the same quality at appreciably less because that is the whole point of it.
func surroundBitrate(codec string, channels int) string {
	if codec == "eac3" {
		if channels > 2 {
			return "384k"
		}
		return "192k"
	}
	if channels > 2 {
		return "448k"
	}
	return "192k"
}

// hdrToSDRFilter is the tone-mapping chain, or "" when this FFmpeg build cannot
// perform one.
//
// The chain is the standard one and every step of it is load-bearing: tone
// mapping is only meaningful in linear light, so the transfer function has to be
// undone first (zscale t=linear), the mapping itself has to happen in floating
// point or it bands visibly (format=gbrpf32le), the gamut has to be brought back
// from BT.2020 to BT.709, and the result has to be re-encoded with a BT.709
// transfer. Hable is the operator that keeps highlights rather than clipping
// them, and desat=0 stops the desaturation pass that makes bright scenes grey.
//
// It needs zscale, which is libzimg, which is not in every FFmpeg build — hence
// the runtime check. A build without it gets no tone mapping rather than a
// session that dies on an unknown filter.
func hdrToSDRFilter() string {
	if !ffmpegHasFilter("zscale") || !ffmpegHasFilter("tonemap") {
		warnNoTonemapOnce.Do(func() {
			log.Printf("streaming: this FFmpeg has no zscale/tonemap filter — HDR sources " +
				"that have to be re-encoded will come out washed out. Install an FFmpeg " +
				"built with libzimg to fix it.")
		})
		return ""
	}
	return "zscale=t=linear:npl=100," +
		"format=gbrpf32le," +
		"zscale=p=bt709," +
		"tonemap=tonemap=hable:desat=0," +
		"zscale=t=bt709:m=bt709:r=tv," +
		"format=yuv420p"
}

var (
	filterOnce        sync.Once
	filterSet         map[string]bool
	warnNoTonemapOnce sync.Once
)

// setFilterSetForTest pins the filter inventory, so a test can exercise both
// sides of the tone-mapping decision regardless of what the local FFmpeg
// happens to be built with.
func setFilterSetForTest(names ...string) {
	filterOnce.Do(func() {}) // consume the once, so no probe overwrites this
	filterSet = map[string]bool{}
	for _, n := range names {
		filterSet[n] = true
	}
}

// ffmpegHasFilter reports whether the FFmpeg on this host provides a filter.
//
// Asked once per process and cached: `ffmpeg -filters` is a fork and a parse,
// and the answer cannot change while the binary does not.
func ffmpegHasFilter(name string) bool {
	filterOnce.Do(func() {
		filterSet = map[string]bool{}
		out, err := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "quiet", "-filters").Output()
		if err != nil {
			return
		}
		for _, line := range strings.Split(string(out), "\n") {
			// Rows look like " ... zscale           V->V       Apply resizing...".
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				filterSet[fields[1]] = true
			}
		}
	})
	return filterSet[name]
}
