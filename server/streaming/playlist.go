package streaming

import (
	"fmt"
	"strings"
)

// GenerateMasterPlaylist builds the master M3U8 playlist that references
// the video variant, audio streams, and subtitle tracks.
func GenerateMasterPlaylist(session *TranscodeSession, probe *ProbeResult, baseURL string) string {
	var sb strings.Builder

	sb.WriteString("#EXTM3U\n")
	sb.WriteString("#EXT-X-VERSION:6\n")

	// --- Audio media entries ---
	if probe != nil && len(probe.Audio) > 0 {
		for i, audio := range probe.Audio {
			name := audio.Title
			if name == "" {
				name = fmt.Sprintf("Audio %d", i+1)
			}
			lang := audio.Language
			if lang == "" {
				lang = "und"
			}
			isDefault := "NO"
			if i == 0 {
				isDefault = "YES"
			}
			// Audio is muxed into the variant playlist (same .ts segments)
			// so the URI points to the variant playlist
			fmt.Fprintf(&sb,
				"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"%s\",LANGUAGE=\"%s\",DEFAULT=%s,AUTOSELECT=YES,URI=\"%s/api/v1/stream/%d/%s/variant.m3u8\"\n",
				escapeM3U8(name), lang, isDefault, baseURL, session.MediaID, session.ID,
			)
		}
	}

	// --- Subtitle media entries ---
	if probe != nil && len(probe.Subtitles) > 0 {
		for i, sub := range probe.Subtitles {
			name := sub.Title
			if name == "" {
				name = fmt.Sprintf("Subtitles %d", i+1)
			}
			lang := sub.Language
			if lang == "" {
				lang = "und"
			}
			fmt.Fprintf(&sb,
				"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"%s\",LANGUAGE=\"%s\",DEFAULT=NO,AUTOSELECT=NO,URI=\"%s/api/v1/stream/%d/%s/sub_%d.vtt\"\n",
				escapeM3U8(name), lang, baseURL, session.MediaID, session.ID, i,
			)
		}
	}

	// --- Video stream variant ---
	bandwidth := EstimateBandwidth(session.Quality)
	resolution := GetResolutionString(session.Quality)

	// Build CODECS attribute
	codecs := "avc1.64001f"
	if probe != nil && len(probe.Audio) > 0 {
		audioCodec := MapAudioCodecToHLS(probe.Audio[0].Codec)
		codecs += "," + audioCodec
	} else {
		codecs += ",mp4a.40.2"
	}

	// Build STREAM-INF line
	streamInf := fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d,CODECS=\"%s\",RESOLUTION=%s",
		bandwidth, codecs, resolution)

	// Add AUDIO attribute if we have audio entries
	if probe != nil && len(probe.Audio) > 0 {
		streamInf += ",AUDIO=\"audio\""
	}
	// Add SUBTITLES attribute if we have subtitle entries
	if probe != nil && len(probe.Subtitles) > 0 {
		streamInf += ",SUBTITLES=\"subs\""
	}

	sb.WriteString(streamInf + "\n")
	fmt.Fprintf(&sb, "%s/api/v1/stream/%d/%s/variant.m3u8\n", baseURL, session.MediaID, session.ID)

	return sb.String()
}

// escapeM3U8 escapes double quotes in M3U8 attribute values.
func escapeM3U8(s string) string {
	return strings.ReplaceAll(s, "\"", "\\\"")
}
