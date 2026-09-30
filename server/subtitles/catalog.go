package subtitles

import (
	"fmt"
	"strings"

	"project-player/server/streaming"
)

// Catalog builds the unified subtitle list for /api/media/:id/tracks: every
// text subtitle stream in the file is listed immediately (ready=false) and
// flips to ready=true once its .vtt has been extracted and registered.
func Catalog(mediaID int, probe *streaming.ProbeResult) []Track {
	if probe == nil {
		list, _ := List(mediaID)
		return list
	}

	ready, _ := List(mediaID)
	readyByLang := make(map[string]Track, len(ready))
	for _, t := range ready {
		readyByLang[t.Lang] = t
	}

	seen := map[string]int{}
	var out []Track
	for _, s := range probe.Subtitles {
		code := normalizeLang(s.Language)

		if s.Image {
			// Bitmap subtitles (PGS/VOBSUB) cannot become WebVTT, so they are
			// delivered by burning them into the video while transcoding. They
			// need no extraction, hence Ready.
			//
			// Their key lives in a separate namespace: text keys name .vtt files
			// on disk and are derived by advancing `seen`, so letting a bitmap
			// track take part would rename every text track that follows it and
			// break the pairing with planTextSubtitles.
			out = append(out, Track{
				Lang:       fmt.Sprintf("img%d", s.TypedIndex),
				Language:   code,
				Name:       subtitleTitle(code, s),
				Ready:      true,
				TypedIndex: s.TypedIndex,
				Image:      true,
				Forced:     isForced(s),
				Default:    s.Default,
			})
			continue
		}

		key := code
		if seen[code] > 0 {
			key = fmt.Sprintf("%s%d", code, seen[code]+1)
		}
		seen[code]++

		if rt, ok := readyByLang[key]; ok {
			// Ready and Partial come from the DB row; everything describing the
			// stream itself comes from the probe, which is the only source that
			// knows about positions and dispositions.
			rt.TypedIndex = s.TypedIndex
			rt.Language = code
			rt.Forced = isForced(s)
			rt.Default = s.Default
			out = append(out, rt)
			continue
		}
		// Discovered by the probe but not extracted yet: listed so the language
		// shows up in the UI immediately, with ready=false driving the client's
		// "extraction en cours" state.
		out = append(out, Track{
			Lang:       key,
			Language:   code,
			Name:       subtitleTitle(code, s),
			Ready:      false,
			TypedIndex: s.TypedIndex,
			Forced:     isForced(s),
			Default:    s.Default,
		})
	}
	return out
}

// isForced dit si une piste ne sous-titre que les dialogues étrangers. Le
// drapeau du conteneur d'abord ; à défaut, le titre, parce que beaucoup de
// fichiers n'annoncent leur piste forcée que par son nom (« French Forced »,
// « FR Forcés »). Sans ça, le client ne distinguait pas la piste forcée de la
// complète et, d'un épisode à l'autre, basculait de l'une à l'autre.
func isForced(s streaming.SubtitleStreamInfo) bool {
	if s.Forced {
		return true
	}
	title := strings.ToLower(s.Title)
	return strings.Contains(title, "forced") || strings.Contains(title, "forcé")
}
