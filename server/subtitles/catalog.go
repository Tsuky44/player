package subtitles

import (
	"fmt"

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
		if s.Image {
			continue
		}
		code := normalizeLang(s.Language)
		key := code
		if seen[code] > 0 {
			key = fmt.Sprintf("%s%d", code, seen[code]+1)
		}
		seen[code]++

		if rt, ok := readyByLang[key]; ok {
			out = append(out, rt)
			continue
		}
		out = append(out, Track{
			Lang:  key,
			Name:  subtitleTitle(code, s),
			Ready: false,
		})
	}
	return out
}
