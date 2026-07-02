package subtitles

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	ffmpeg "github.com/u2takey/ffmpeg-go"

	"project-player/server/streaming"
)

// mediaLocks serializes extraction per media so a background auto-extract and a
// manual one can never run on the same file concurrently (which would race on
// the .vtt output files).
var mediaLocks sync.Map // map[int]*sync.Mutex

func mediaLock(mediaID int) *sync.Mutex {
	m, _ := mediaLocks.LoadOrStore(mediaID, &sync.Mutex{})
	return m.(*sync.Mutex)
}

var outputDirOnce sync.Once

// OutputDir returns the writable directory where extracted .vtt files are
// stored. Media libraries are frequently mounted read-only, so subtitles are
// never written next to the source video. Override with SUBTITLE_DIR.
func OutputDir() string {
	dir := os.Getenv("SUBTITLE_DIR")
	if dir == "" {
		dir = filepath.Join("data", "subtitles")
	}
	outputDirOnce.Do(func() {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			log.Printf("subtitles: failed to create output dir %q: %v", dir, err)
		}
	})
	return dir
}

// Discovered describes one extracted subtitle ready to be registered.
type Discovered struct {
	Language string
	Title    string
	Path     string
}

// ExtractAndRegister probes the media, extracts every text subtitle track to a
// .vtt file and registers it in the database. Skips work if already present.
func ExtractAndRegister(mediaID int, videoPath string) error {
	_, err := extractAndRegister(mediaID, videoPath, false)
	return err
}

// ForceExtractAndRegister re-probes and re-extracts every text subtitle track,
// overwriting existing .vtt files and refreshing the database rows.
func ForceExtractAndRegister(mediaID int, videoPath string) (int, error) {
	return extractAndRegister(mediaID, videoPath, true)
}

// EnsureExtractedSync extracts subtitles only if none are registered yet and
// returns how many tracks are available. Safe to call from a background task.
func EnsureExtractedSync(mediaID int, videoPath string) (int, error) {
	return extractAndRegister(mediaID, videoPath, false)
}

func extractAndRegister(mediaID int, videoPath string, force bool) (int, error) {
	if videoPath == "" {
		return 0, nil
	}

	// Serialize per media so background + manual extraction never race.
	lock := mediaLock(mediaID)
	lock.Lock()
	defer lock.Unlock()

	if !force {
		if n, _ := CountForMedia(mediaID); n > 0 {
			return n, nil // already extracted, nothing to do
		}
	}

	discovered, err := ExtractTextSubtitles(mediaID, videoPath, force)
	if err != nil {
		return 0, err
	}

	keep := make(map[string]bool, len(discovered))
	for _, d := range discovered {
		if err := Register(mediaID, d.Language, d.Title, d.Path); err != nil {
			log.Printf("subtitles: register %d/%s: %v", mediaID, d.Language, err)
			continue
		}
		keep[d.Language] = true
	}

	if err := PruneExcept(mediaID, keep); err != nil {
		log.Printf("subtitles: prune %d: %v", mediaID, err)
	}
	return len(discovered), nil
}

// ExtractTextSubtitles inspects the container with ffprobe (via our typed probe
// wrapper) and extracts each *text* subtitle stream to a WebVTT file in the
// writable output directory, using the github.com/u2takey/ffmpeg-go wrapper so
// the FFmpeg invocation is built from structured arguments instead of
// hand-formatted strings.
//
// Files are written to OutputDir() (NOT next to the video) because media
// libraries are commonly mounted read-only — writing a sidecar there fails with
// FFmpeg "Read-only file system" (exit 226 = AVERROR(EROFS)).
//
// Image-based subtitles (PGS/VOBSUB/DVB) cannot be turned into text and are
// skipped — they remain available natively in Direct Play.
func ExtractTextSubtitles(mediaID int, videoPath string, force bool) ([]Discovered, error) {
	if videoPath == "" {
		return nil, nil
	}
	probe, err := streaming.ProbeTracks(videoPath)
	if err != nil {
		return nil, err
	}

	dir := OutputDir()

	var out []Discovered
	seen := map[string]int{}
	for _, s := range probe.Subtitles {
		if s.Image {
			continue
		}
		code := normalizeLang(s.Language)
		// Disambiguate several tracks sharing a language (e.g. full + forced).
		key := code
		if seen[code] > 0 {
			key = fmt.Sprintf("%s%d", code, seen[code]+1)
		}
		seen[code]++

		vttPath := filepath.Join(dir, fmt.Sprintf("m%d.%s.vtt", mediaID, key))
		if force {
			if err := extractTrack(videoPath, s.TypedIndex, vttPath); err != nil {
				log.Printf("subtitles: extract media %d s:%d failed: %v", mediaID, s.TypedIndex, err)
				continue
			}
			log.Printf("subtitles: extracted %s", filepath.Base(vttPath))
		} else if _, statErr := os.Stat(vttPath); statErr != nil {
			if err := extractTrack(videoPath, s.TypedIndex, vttPath); err != nil {
				log.Printf("subtitles: extract media %d s:%d failed: %v", mediaID, s.TypedIndex, err)
				continue
			}
			log.Printf("subtitles: extracted %s", filepath.Base(vttPath))
		}

		out = append(out, Discovered{
			Language: key,
			Title:    subtitleTitle(code, s),
			Path:     filepath.ToSlash(vttPath),
		})
	}
	return out, nil
}

// extractTrack runs `ffmpeg -i <video> -map 0:s:N -c:s webvtt -f webvtt <out>`
// through the wrapper, writing atomically into the (writable) output directory.
func extractTrack(videoPath string, typedIndex int, outPath string) error {
	tmp := outPath + ".tmp.vtt"
	var stderr bytes.Buffer
	err := ffmpeg.Input(videoPath).
		Output(tmp, ffmpeg.KwArgs{
			"map": fmt.Sprintf("0:s:%d", typedIndex),
			"c:s": "webvtt",
			"f":   "webvtt",
		}).
		OverWriteOutput().
		WithErrorOutput(&stderr).
		Silent(true).
		Run()
	if err != nil {
		os.Remove(tmp)
		if msg := strings.TrimSpace(lastLine(stderr.String())); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	return os.Rename(tmp, outPath)
}

// lastLine returns the last non-empty line of s (the most useful FFmpeg error).
func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) != "" {
			return lines[i]
		}
	}
	return ""
}

func subtitleTitle(code string, s streaming.SubtitleStreamInfo) string {
	label := LanguageLabel(code)
	var tags []string
	if s.Default {
		tags = append(tags, "Par défaut")
	}
	if s.Forced {
		tags = append(tags, "Forcé")
	}
	if t := strings.TrimSpace(s.Title); t != "" && !isFlagWord(t) {
		tags = append(tags, t)
	}
	if len(tags) == 0 {
		return label
	}
	return fmt.Sprintf("%s (%s)", label, strings.Join(tags, " "))
}

func isFlagWord(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "forced", "forcé", "default", "par défaut":
		return true
	default:
		return false
	}
}
