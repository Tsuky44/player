package streaming

import (
	"fmt"
	"strings"
)

// The master playlist is written here rather than served from FFmpeg's own file.
//
// FFmpeg's master is unusable in a browser for two independent reasons, and both
// only bite on some media, which is what made this look like a flaky player
// rather than a broken playlist:
//
//   - BANDWIDTH is optional to FFmpeg and mandatory to the format. It writes
//     "#EXT-X-STREAM-INF:BANDWIDTH=%d" only when it can work out a bitrate for
//     the variant, and then appends RESOLUTION, CODECS and AUDIO regardless —
//     so a variant with no known bitrate comes out as a line STARTING WITH A
//     COMMA, with no tag on it at all. A copied video stream out of a Matroska
//     file has exactly that: MKV stores no per-stream bitrate, and `-c:v copy`
//     has no encoder to ask. hls.js matches variants on the literal
//     "#EXT-X-STREAM-INF:" prefix, so the video variant becomes invisible and
//     the only playable things left in the file are the audio renditions.
//     The viewer gets sound over a spinner that never ends — and when the audio
//     is copied too (already-stereo AAC), nothing is left to play at all and the
//     media does not load.
//
//   - it declares every audio rendition DEFAULT=YES. A group may name exactly
//     one default; a player handed several takes the first, so the ?audio=N the
//     session was started for is ignored and the film plays in whatever language
//     happens to be first in the container. On the web that is the whole audio
//     selection mechanism, because a browser exposes no track API over a media
//     stream and the client switches language by restarting the session.
//
// Everything the master needs is known at /start — resolution from the probe,
// bandwidth from the preset or the file, languages from the probe — so authoring
// it costs nothing and removes the dependency on what FFmpeg felt like writing.

// audioGroupID names the audio rendition group.
//
// It appears only in the master, which is ours, so it need not match the
// "group_aud" FFmpeg derives from -var_stream_map's `agroup:aud`: the child
// playlists never mention a group. What must match is the GROUP-ID on the
// renditions below and the AUDIO attribute on the variant.
const audioGroupID = "audio"

// videoVariantPlaylist is the child playlist FFmpeg writes for the video
// rendition, which -var_stream_map always declares first (v:0).
const videoVariantPlaylist = "stream_0.m3u8"

// audioVariantPlaylist returns the child playlist of the k-th published audio
// rendition. The video variant takes index 0, so audio rendition k is stream
// k+1 — the same numbering BuildFFmpegArgs hands to -var_stream_map.
func audioVariantPlaylist(k int) string {
	return fmt.Sprintf("stream_%d.m3u8", k+1)
}

// MasterPlaylistOptions describes the master a session publishes.
type MasterPlaylistOptions struct {
	Probe   *ProbeResult
	Quality string
	// AudioTypedIndexes lists the source audio tracks published as renditions,
	// in master-playlist order — the same slice handed to -var_stream_map and
	// returned to the client as audio_map.
	AudioTypedIndexes []int
	// DefaultAudioTypedIndex is the source track the session was started for. It
	// becomes the group's one DEFAULT=YES rendition, which is what makes the
	// language the client asked for the language it gets.
	DefaultAudioTypedIndex int
	// BandwidthBps is what the variant is advertised at. Zero falls back to the
	// preset's own ceiling.
	BandwidthBps int
	// Caps is the client declaration the session was built from. The renditions
	// have to be described as they are actually being produced, and since
	// PlanAudio is what decides that, the master has to ask it the same
	// question with the same inputs.
	Caps Capabilities
}

// caps resolves the client declaration, defaulting to the legacy one — for the
// same reason TranscodeOptions.caps does.
func (o MasterPlaylistOptions) caps() Capabilities {
	if o.Caps.VideoCodecs == nil || o.Caps.AudioCodecs == nil {
		return LegacyCapabilities()
	}
	return o.Caps
}

// BuildMasterPlaylist renders the master playlist for a session.
func BuildMasterPlaylist(opt MasterPlaylistOptions) string {
	var b strings.Builder
	b.WriteString("#EXTM3U\n")
	b.WriteString("#EXT-X-VERSION:6\n")
	b.WriteString("#EXT-X-INDEPENDENT-SEGMENTS\n")

	group := ""
	if len(opt.AudioTypedIndexes) > 0 {
		group = audioGroupID
		defaultPos := defaultRenditionPosition(opt.AudioTypedIndexes, opt.DefaultAudioTypedIndex)
		for k, srcIdx := range opt.AudioTypedIndexes {
			b.WriteString(`#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="` + group + `"`)
			b.WriteString(`,NAME="` + audioRenditionName(opt.Probe, srcIdx, k) + `"`)
			if lang := audioLanguage(opt.Probe, srcIdx); lang != "" {
				b.WriteString(`,LANGUAGE="` + lang + `"`)
			}
			// Every rendition is auto-selectable, exactly one is the default.
			b.WriteString(`,AUTOSELECT=YES,DEFAULT=` + yesNo(k == defaultPos))
			// CHANNELS must be what the rendition actually carries. It used to
			// be a hard-coded "2", which was true while every rendition was
			// folded to stereo and became a lie the moment surround could
			// survive — and it is not a cosmetic lie: a player picks a
			// rendition partly on this number, so a 5.1 track advertised as
			// stereo is one a client with an amplifier may pass over.
			plan := PlanAudio(opt.Probe, srcIdx, opt.caps(), presetFor(opt.Quality))
			b.WriteString(fmt.Sprintf(`,CHANNELS="%d"`, plan.Channels))
			b.WriteString(`,URI="` + audioVariantPlaylist(k) + `"` + "\n")
		}
	}

	bandwidth := opt.BandwidthBps
	if bandwidth <= 0 {
		bandwidth = EstimateBandwidth(opt.Quality)
	}
	b.WriteString(fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d", bandwidth))
	if w, h, ok := outputResolution(opt.Probe, presetFor(opt.Quality)); ok {
		b.WriteString(fmt.Sprintf(",RESOLUTION=%dx%d", w, h))
	}
	if group != "" {
		b.WriteString(`,AUDIO="` + group + `"`)
	}
	// No CODECS attribute, deliberately. It is optional, and a wrong value is far
	// worse than a missing one: a player checks it against the decoders it has
	// before fetching a single segment, so one bad profile/level string makes it
	// refuse a stream it could actually have played. On the copy path the exact
	// string is the source's, which is not something this side knows — both hls.js
	// and mpv read the real codecs out of the first segment anyway.
	b.WriteString("\n" + videoVariantPlaylist + "\n")

	return b.String()
}

// defaultRenditionPosition locates the requested source track in the published
// layout. SelectAudioRenditions guarantees it is there; position 0 is the
// fallback for a caller that got it wrong, since a group with no default at all
// leaves the choice to the player.
func defaultRenditionPosition(audioTypedIndexes []int, requested int) int {
	for k, srcIdx := range audioTypedIndexes {
		if srcIdx == requested {
			return k
		}
	}
	return 0
}

// audioRenditionName is the human-readable label a player shows for a
// rendition. NAME is mandatory, so this always returns something.
func audioRenditionName(probe *ProbeResult, typedIndex, position int) string {
	if probe != nil && typedIndex >= 0 && typedIndex < len(probe.Audio) {
		if title := sanitizeAttrValue(probe.Audio[typedIndex].Title); title != "" {
			return title
		}
		if lang := sanitizeAttrValue(probe.Audio[typedIndex].Language); lang != "" {
			return lang
		}
	}
	return fmt.Sprintf("Audio %d", position+1)
}

// sanitizeAttrValue makes a probe string safe inside a quoted playlist
// attribute. Track titles come from the file and are arbitrary text: a quote or
// a newline in one would end the attribute — or the line — early and corrupt
// every tag after it.
func sanitizeAttrValue(s string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r == '"' || r == '\\' || r == ',':
			continue
		case r < 0x20 || r == 0x7f:
			continue
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

func yesNo(b bool) string {
	if b {
		return "YES"
	}
	return "NO"
}
