package subtitles

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"

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

// extractionSlots bounds how many extractions run at once. Each one is a full
// sequential read of a media file, so letting several viewers trigger them
// concurrently would saturate the storage the transcoder is also reading from.
var extractionSlots = make(chan struct{}, extractionConcurrency())

func extractionConcurrency() int {
	value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("SUBTITLE_EXTRACTION_CONCURRENCY")))
	if err != nil || value < 1 {
		return 2
	}
	return value
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

// ForceExtractAndRegister re-probes and re-extracts every text subtitle track,
// overwriting existing .vtt files and refreshing the database rows.
func ForceExtractAndRegister(mediaID int, videoPath string) (int, error) {
	return extractAndRegister(mediaID, videoPath, true)
}

// headSeconds is how much media the fast first pass covers.
//
// Sized so it stays ahead of the complete pass: on a 30 GB remux at ~150 MB/s
// the head costs ~25s of I/O while the full pass needs ~200s — by which point
// the viewer is barely 3 minutes in, well inside the head's coverage.
const headSeconds = 900

// headThresholdBytes is the file size above which the two-phase extraction is
// worth it. Below it the complete pass is quick enough that the extra re-attach
// on the client would cost more than it saves (a 2 GB episode extracts in
// seconds).
const headThresholdBytes = 6 << 30 // 6 GiB

// extractionNiceness deprioritises extraction against the transcoder, which is
// usually reading the same file at the same time.
const extractionNiceness = 10

// EnsureExtractedSync makes subtitles available for a media, extracting them on
// demand if needed, and returns how many tracks are available.
//
// Nothing is extracted at scan time: the indexer's probe already records every
// subtitle stream in tracks_json, so the UI can list the languages immediately,
// and reading each file end-to-end during a library scan is by far the most
// expensive thing the scan could do. The actual extraction happens here, once,
// on first playback.
//
// Large files are done in two phases so the wait is never visible: a bounded
// head pass publishes usable subtitles within seconds (marked partial), then the
// complete pass replaces them. Safe to call from a background task.
func EnsureExtractedSync(mediaID int, videoPath string) (int, error) {
	if videoPath == "" {
		return 0, nil
	}

	lock := mediaLock(mediaID)
	lock.Lock()
	defer lock.Unlock()

	// Already fully extracted — nothing to do. Checked before taking a slot so a
	// no-op call never queues behind a real extraction.
	if n, err := CountCompleteForMedia(mediaID); err == nil && n > 0 {
		return n, nil
	}

	extractionSlots <- struct{}{}
	defer func() { <-extractionSlots }()

	if info, err := os.Stat(videoPath); err == nil && info.Size() >= headThresholdBytes {
		head, headErr := extractTextSubtitles(mediaID, videoPath, true, headSeconds)
		if headErr != nil {
			log.Printf("subtitles: head pass media %d failed: %v", mediaID, headErr)
		} else if len(head) > 0 {
			registerAll(mediaID, head, true)
			log.Printf("subtitles: media %d — %d track(s) usable from head pass, completing…",
				mediaID, len(head))
		}
	}

	full, err := extractTextSubtitles(mediaID, videoPath, true, 0)
	if err != nil {
		return 0, err
	}
	registerAll(mediaID, full, false)
	return len(full), nil
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

	registerAll(mediaID, discovered, false)
	return len(discovered), nil
}

// registerAll persists a batch of extracted tracks and drops rows for languages
// that no longer exist in the file.
func registerAll(mediaID int, discovered []Discovered, partial bool) {
	keep := make(map[string]bool, len(discovered))
	for _, d := range discovered {
		if err := Register(mediaID, d.Language, d.Title, d.Path, partial); err != nil {
			log.Printf("subtitles: register %d/%s: %v", mediaID, d.Language, err)
			continue
		}
		keep[d.Language] = true
	}
	if err := PruneExcept(mediaID, keep); err != nil {
		log.Printf("subtitles: prune %d: %v", mediaID, err)
	}
}

// plannedTrack is one text subtitle stream slated for extraction.
type plannedTrack struct {
	typedIndex int
	key        string // language code, disambiguated ("fr", "fr2"…)
	title      string
	path       string
}

// planTextSubtitles maps the container's text subtitle streams to their output
// paths. The key derivation (language code, suffixed on collision) must stay
// identical to Catalog's, since that is what pairs a probe-discovered track with
// its extracted file.
func planTextSubtitles(mediaID int, probe *streaming.ProbeResult, dir string) []plannedTrack {
	var planned []plannedTrack
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

		planned = append(planned, plannedTrack{
			typedIndex: s.TypedIndex,
			key:        key,
			title:      subtitleTitle(code, s),
			path:       filepath.Join(dir, fmt.Sprintf("m%d.%s.vtt", mediaID, key)),
		})
	}
	return planned
}

// ExtractTextSubtitles inspects the container with ffprobe (via our typed probe
// wrapper) and extracts every *text* subtitle stream to a WebVTT file in the
// writable output directory.
//
// Files are written to OutputDir() (NOT next to the video) because media
// libraries are commonly mounted read-only — writing a sidecar there fails with
// FFmpeg "Read-only file system" (exit 226 = AVERROR(EROFS)).
//
// Image-based subtitles (PGS/VOBSUB/DVB) cannot be turned into text and are
// skipped — they remain available natively in Direct Play.
func ExtractTextSubtitles(mediaID int, videoPath string, force bool) ([]Discovered, error) {
	return extractTextSubtitles(mediaID, videoPath, force, 0)
}

// extractTextSubtitles extracts every planned track. limitSeconds > 0 bounds the
// read to the first N seconds of the media (the "head" pass).
func extractTextSubtitles(mediaID int, videoPath string, force bool, limitSeconds int) ([]Discovered, error) {
	if videoPath == "" {
		return nil, nil
	}
	probe, err := streaming.ProbeTracks(videoPath)
	if err != nil {
		return nil, err
	}

	planned := planTextSubtitles(mediaID, probe, OutputDir())
	if len(planned) == 0 {
		return nil, nil
	}

	todo := planned
	if !force {
		todo = nil
		for _, p := range planned {
			if _, statErr := os.Stat(p.path); statErr != nil {
				todo = append(todo, p)
			}
		}
	}

	if len(todo) > 0 {
		if err := extractTracks(videoPath, todo, limitSeconds); err != nil {
			return nil, err
		}
		log.Printf("subtitles: media %d — extracted %d track(s)%s",
			mediaID, len(todo), limitLabel(limitSeconds))
	}

	var out []Discovered
	for _, p := range planned {
		if _, statErr := os.Stat(p.path); statErr != nil {
			continue // extraction failed for this track — skip it
		}
		out = append(out, Discovered{
			Language: p.key,
			Title:    p.title,
			Path:     filepath.ToSlash(p.path),
		})
	}
	return out, nil
}

func limitLabel(limitSeconds int) string {
	if limitSeconds > 0 {
		return fmt.Sprintf(" (head, %ds)", limitSeconds)
	}
	return ""
}

// extractTracks writes every requested subtitle track in a SINGLE FFmpeg pass.
//
// Extraction cost is pure sequential I/O proportional to the container size —
// the CPU work is negligible. One pass per track therefore read the whole file
// N times; one pass with N outputs reads it once, dividing the dominant cost by
// the track count. Each output is written to a temp file and renamed, so a
// client fetching a .vtt mid-extraction always sees a complete document.
//
// limitSeconds > 0 stops the read after that much media, which is what makes
// the head pass cheap: the read is bounded, not the whole file.
func extractTracks(videoPath string, tracks []plannedTrack, limitSeconds int) error {
	if len(tracks) == 0 {
		return nil
	}

	args := []string{"-hide_banner", "-loglevel", "error", "-y"}
	// Video and audio are never needed here; skipping them keeps FFmpeg from
	// setting up decoders it will not use.
	args = append(args, "-vn", "-an", "-i", videoPath)

	tmps := make([]string, len(tracks))
	for i, t := range tracks {
		tmps[i] = t.path + ".tmp.vtt"
		args = append(args, "-map", fmt.Sprintf("0:s:%d", t.typedIndex))
		if limitSeconds > 0 {
			args = append(args, "-t", strconv.Itoa(limitSeconds))
		}
		args = append(args, "-c:s", "webvtt", "-f", "webvtt", tmps[i])
	}

	cmd := exec.Command("ffmpeg", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		removeAll(tmps)
		return err
	}
	// Extraction routinely runs while a transcode is already reading the same
	// file; yield CPU to it rather than competing.
	if cmd.Process != nil {
		_ = syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, extractionNiceness)
	}

	if err := cmd.Wait(); err != nil {
		removeAll(tmps)
		if msg := strings.TrimSpace(lastLine(stderr.String())); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}

	for i, t := range tracks {
		if err := os.Rename(tmps[i], t.path); err != nil {
			return fmt.Errorf("rename %s: %w", filepath.Base(t.path), err)
		}
	}
	return nil
}

func removeAll(paths []string) {
	for _, p := range paths {
		_ = os.Remove(p)
	}
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
