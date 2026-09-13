package streaming

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/playbackauth"

	"github.com/julienschmidt/httprouter"
)

// Timeline previews: the still shown above the scrubber where the pointer is.
//
// Each still is one keyframe, pulled with an input seek and `-skip_frame
// nokey`: FFmpeg jumps straight to the keyframe before the second asked for and
// decodes that single picture, never the GOP after it. Measured at ~40 ms for a
// 1080p H.264 file and ~170 ms for a 4K HEVC 10-bit one on one core — which is
// what makes on-demand generation viable at all. A sprite sheet built in one
// pass would have to read the whole file before the first hover could be
// answered.
//
// So there are two producers writing into the same on-disk cache:
//   - the hover itself, served right away, jumping every queue;
//   - a background pass, started by the client once the picture is on screen
//     (never before, so it cannot compete with the start of playback), which
//     fills the timeline coarse-to-fine on one low-priority core and stops as
//     soon as the playback ticket that asked for it is gone.
const (
	previewWidth       = 480
	previewTargetCount = 600
	previewMinInterval = 4
	previewMaxInterval = 20
	// Bumped whenever the extraction changes in a way that should not reuse
	// stills already on disk.
	previewVersion = 1

	previewExtractTimeout = 20 * time.Second
	// Consecutive failures after which a background pass gives up on a file.
	previewMaxFailures = 5
	// Background passes allowed at once, across every viewer.
	previewMaxWarmJobs = 2
	// Hover-driven extractions allowed at once, across every viewer.
	previewForegroundSlots = 2
	defaultPreviewCacheMB  = 2048
)

// PreviewManifest is what a client needs to map a position to a still.
type PreviewManifest struct {
	// Interval is the spacing between stills, in seconds. Still i shows
	// second i*Interval.
	Interval int `json:"interval"`
	Count    int `json:"count"`
	Width    int `json:"width"`
	Height   int `json:"height"`
}

// previewInterval spreads about previewTargetCount stills over the file, never
// closer than a typical GOP (tighter would only repeat the same keyframe) and
// never so far apart that a scrub feels like a slideshow.
func previewInterval(duration float64) int {
	if duration <= 0 {
		return previewMinInterval
	}
	interval := int(math.Ceil(duration / previewTargetCount))
	if interval < previewMinInterval {
		return previewMinInterval
	}
	if interval > previewMaxInterval {
		return previewMaxInterval
	}
	return interval
}

func previewCount(duration float64, interval int) int {
	if duration <= 0 || interval <= 0 {
		return 0
	}
	return int(math.Ceil(duration / float64(interval)))
}

// previewHeight keeps the source's aspect at previewWidth, rounded to even as
// the scaler's -2 does.
func previewHeight(width, height int) int {
	if width <= 0 || height <= 0 {
		return previewWidth * 9 / 16
	}
	h := int(math.Round(float64(previewWidth) * float64(height) / float64(width)))
	if h%2 != 0 {
		h++
	}
	if h < 2 {
		h = 2
	}
	return h
}

// previewOrder is the background pass's order: every 2^k-th still first, then
// the halves between them. A hover lands near a finished still after a few
// seconds wherever it lands, instead of only near the start of the file.
func previewOrder(count int) []int {
	if count <= 0 {
		return nil
	}
	stride := 1
	for stride*2 < count {
		stride *= 2
	}
	seen := make([]bool, count)
	order := make([]int, 0, count)
	for ; stride >= 1; stride /= 2 {
		for i := 0; i < count; i += stride {
			if !seen[i] {
				seen[i] = true
				order = append(order, i)
			}
		}
	}
	return order
}

// previewArgs extracts one still at [second] to stdout as JPEG.
//
// -map 0:V:0 skips attached cover art, which a capital V excludes. Scaling runs
// before tone mapping for the same reason it does on the transcoding path: the
// tone mapper then works on a few hundred thousand pixels instead of eight
// million. The final yuvj420p is what the MJPEG encoder accepts on every FFmpeg
// the server may be deployed with.
func previewArgs(filePath string, second int, tonemap bool, keyframeOnly bool, threads int) []string {
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin",
		"-threads", strconv.Itoa(threads)}
	if keyframeOnly {
		args = append(args, "-skip_frame", "nokey")
	}
	args = append(args,
		"-ss", strconv.Itoa(second), "-noaccurate_seek",
		"-i", filePath,
		"-map", "0:V:0", "-an", "-sn", "-dn",
		"-frames:v", "1",
	)
	filters := []string{fmt.Sprintf("scale=%d:-2:flags=bilinear", previewWidth)}
	if tonemap {
		if tm := hdrToSDRFilter(); tm != "" {
			filters = append(filters, tm)
		}
	}
	filters = append(filters, "format=yuvj420p")
	args = append(args,
		"-vf", strings.Join(filters, ","),
		"-c:v", "mjpeg", "-q:v", "5",
		"-f", "image2pipe", "pipe:1",
	)
	return args
}

// previewSet is one file's stills: where they live and how they are spaced.
type previewSet struct {
	mediaID  int
	filePath string
	size     int64
	modTime  time.Time
	dir      string
	tonemap  bool
	manifest PreviewManifest
}

func (s *previewSet) path(index int) string {
	return filepath.Join(s.dir, strconv.Itoa(index)+".jpg")
}

type previewCall struct {
	done chan struct{}
	err  error
}

type previewWarmJob struct {
	cancel  context.CancelFunc
	done    chan struct{}
	started time.Time
}

type previewGenerator struct {
	root    string
	tickets *playbackauth.Store
	// run executes one extraction; replaced in tests.
	run func(ctx context.Context, args []string, background bool) ([]byte, error)

	mu       sync.Mutex
	sets     map[int]*previewSet
	inflight map[string]*previewCall
	jobs     map[string]*previewWarmJob

	foreground chan struct{}
	pruneMu    sync.Mutex
}

func newPreviewGenerator(root string, tickets *playbackauth.Store) *previewGenerator {
	return &previewGenerator{
		root:       root,
		tickets:    tickets,
		run:        runPreviewFFmpeg,
		sets:       map[int]*previewSet{},
		inflight:   map[string]*previewCall{},
		jobs:       map[string]*previewWarmJob{},
		foreground: make(chan struct{}, previewForegroundSlots),
	}
}

// previewRoot is where stills are cached. Libraries are often mounted
// read-only, so like subtitles they never go next to the video.
func previewRoot() string {
	if dir := os.Getenv("PREVIEW_DIR"); dir != "" {
		return dir
	}
	return filepath.Join("data", "previews")
}

func previewCacheBytes() int64 {
	raw := strings.TrimSpace(os.Getenv("PREVIEW_CACHE_MB"))
	if raw == "" {
		return defaultPreviewCacheMB << 20
	}
	mb, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || mb < 0 {
		return defaultPreviewCacheMB << 20
	}
	return mb << 20
}

func runPreviewFFmpeg(ctx context.Context, args []string, background bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, previewExtractTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	if background {
		// The viewer's own transcode, if there is one, wins every contention.
		lowerProcessPriority(cmd.Process.Pid)
	}
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// newPreviewSet describes a file's stills. The directory name carries the
// file's size and modification time, so a replaced file never serves the
// previous one's pictures.
func newPreviewSet(root string, mediaID int, filePath string, info os.FileInfo, probe *ProbeResult, duration float64) *previewSet {
	interval := previewInterval(duration)
	width, height := 0, 0
	tonemap := false
	if probe != nil && probe.Video != nil {
		width, height = probe.Video.Width, probe.Video.Height
		tonemap = probe.Video.IsHDR()
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%d|%d|%d|%d|%d",
		filePath, info.Size(), info.ModTime().UnixNano(), previewVersion, previewWidth, interval)))
	return &previewSet{
		mediaID:  mediaID,
		filePath: filePath,
		size:     info.Size(),
		modTime:  info.ModTime(),
		dir:      filepath.Join(root, fmt.Sprintf("%d-%x", mediaID, sum[:6])),
		tonemap:  tonemap,
		manifest: PreviewManifest{
			Interval: interval,
			Count:    previewCount(duration, interval),
			Width:    previewWidth,
			Height:   previewHeight(width, height),
		},
	}
}

// cachedSet returns the set remembered for a media, provided its file is
// still the one it was built for.
func (g *previewGenerator) cachedSet(mediaID int, filePath string, info os.FileInfo) *previewSet {
	g.mu.Lock()
	defer g.mu.Unlock()
	set, ok := g.sets[mediaID]
	if !ok || set.filePath != filePath || set.size != info.Size() || !set.modTime.Equal(info.ModTime()) {
		return nil
	}
	return set
}

func (g *previewGenerator) rememberSet(set *previewSet) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.sets[set.mediaID] = set
}

// ensure returns the path of still [index], extracting it first if needed.
//
// Concurrent asks for the same still share one extraction. A foreground ask
// waits for a slot, but gives up with its request; a background one never
// takes a slot, since the warm pass is already its own bounded worker.
func (g *previewGenerator) ensure(ctx context.Context, set *previewSet, index int, background bool) (string, error) {
	path := set.path(index)
	if fileExists(path) {
		return path, nil
	}
	if call, ok := g.joinInflight(path); ok {
		return path, waitPreviewCall(ctx, call)
	}
	if !background {
		select {
		case g.foreground <- struct{}{}:
			defer func() { <-g.foreground }()
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}

	g.mu.Lock()
	if call, ok := g.inflight[path]; ok {
		g.mu.Unlock()
		return path, waitPreviewCall(ctx, call)
	}
	if fileExists(path) {
		g.mu.Unlock()
		return path, nil
	}
	call := &previewCall{done: make(chan struct{})}
	g.inflight[path] = call
	g.mu.Unlock()

	// Detached from the request: a pointer that moved on still leaves a still
	// behind for the next pass over that spot.
	call.err = g.extract(set, index, background)

	g.mu.Lock()
	delete(g.inflight, path)
	g.mu.Unlock()
	close(call.done)
	return path, call.err
}

func (g *previewGenerator) joinInflight(path string) (*previewCall, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	call, ok := g.inflight[path]
	return call, ok
}

func waitPreviewCall(ctx context.Context, call *previewCall) error {
	select {
	case <-call.done:
		return call.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (g *previewGenerator) extract(set *previewSet, index int, background bool) error {
	if err := os.MkdirAll(set.dir, 0o755); err != nil {
		return err
	}
	second := index * set.manifest.Interval
	threads := 2
	if background {
		threads = 1
	}
	data, err := g.run(context.Background(), previewArgs(set.filePath, second, set.tonemap, true, threads), background)
	if err != nil || len(data) == 0 {
		// Some streams hand nothing back when only keyframes are decoded (a
		// seek past the last one, an intra-refresh encode). Decoding normally
		// from the same seek point is slower but always yields a picture.
		data, err = g.run(context.Background(), previewArgs(set.filePath, second, set.tonemap, false, threads), background)
	}
	if err != nil {
		return err
	}
	if len(data) == 0 {
		return errors.New("ffmpeg produced no picture")
	}
	tmp, err := os.CreateTemp(set.dir, ".still-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	// Renamed into place, so a reader never sees half a JPEG.
	return os.Rename(tmp.Name(), set.path(index))
}

// warm starts the background pass for a set, unless one is already running.
// Beyond previewMaxWarmJobs the oldest pass is stopped: its stills stay on
// disk and the next warm of that file resumes where it left off.
func (g *previewGenerator) warm(set *previewSet, ticket [32]byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if job, ok := g.jobs[set.dir]; ok {
		select {
		case <-job.done:
		default:
			return
		}
	}
	for dir, job := range g.jobs {
		select {
		case <-job.done:
			delete(g.jobs, dir)
		default:
		}
	}
	for len(g.jobs) >= previewMaxWarmJobs {
		oldest := ""
		for dir, job := range g.jobs {
			if oldest == "" || job.started.Before(g.jobs[oldest].started) {
				oldest = dir
			}
		}
		g.jobs[oldest].cancel()
		delete(g.jobs, oldest)
	}
	ctx, cancel := context.WithCancel(context.Background())
	job := &previewWarmJob{cancel: cancel, done: make(chan struct{}), started: time.Now()}
	g.jobs[set.dir] = job
	go func() {
		defer close(job.done)
		defer cancel()
		g.runWarm(ctx, set, ticket)
	}()
}

func (g *previewGenerator) runWarm(ctx context.Context, set *previewSet, ticket [32]byte) {
	if err := os.MkdirAll(set.dir, 0o755); err != nil {
		log.Printf("previews: media %d: %v", set.mediaID, err)
		return
	}
	now := time.Now()
	_ = os.Chtimes(set.dir, now, now) // most recently used, for pruning
	g.prune(set.dir)

	started := time.Now()
	made, failures := 0, 0
	for _, index := range previewOrder(set.manifest.Count) {
		if ctx.Err() != nil {
			return
		}
		// Generation lasts as long as someone is watching, and no longer.
		if g.tickets != nil && !g.tickets.IsLive(ticket, set.mediaID) {
			return
		}
		if fileExists(set.path(index)) {
			continue
		}
		if _, err := g.ensure(ctx, set, index, true); err != nil {
			failures++
			if failures >= previewMaxFailures {
				log.Printf("previews: media %d: giving up after %d failures: %v", set.mediaID, failures, err)
				return
			}
			continue
		}
		failures = 0
		made++
	}
	if made > 0 {
		log.Printf("previews: media %d: %d stills in %s", set.mediaID, made, time.Since(started).Round(time.Millisecond))
	}
}

// prune deletes the least recently used sets until the cache fits its budget.
// Sets being warmed are never touched.
func (g *previewGenerator) prune(keep string) {
	g.pruneMu.Lock()
	defer g.pruneMu.Unlock()
	budget := previewCacheBytes()
	if budget <= 0 {
		return
	}
	entries, err := os.ReadDir(g.root)
	if err != nil {
		return
	}
	type usage struct {
		dir     string
		size    int64
		modTime time.Time
	}
	var all []usage
	var total int64
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(g.root, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		var size int64
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			if fi, err := f.Info(); err == nil {
				size += fi.Size()
			}
		}
		total += size
		all = append(all, usage{dir: dir, size: size, modTime: info.ModTime()})
	}
	if total <= budget {
		return
	}
	sort.Slice(all, func(i, j int) bool { return all[i].modTime.Before(all[j].modTime) })
	g.mu.Lock()
	active := map[string]bool{keep: true}
	for dir := range g.jobs {
		active[dir] = true
	}
	g.mu.Unlock()
	for _, u := range all {
		if total <= budget {
			return
		}
		if active[u.dir] {
			continue
		}
		if err := os.RemoveAll(u.dir); err == nil {
			total -= u.size
		}
	}
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// previewSetFor resolves the set for a media, probing the file only when the
// indexer left nothing usable behind.
func (h *Handler) previewSetFor(mediaID int) (*previewSet, error) {
	filePath, err := h.getMediaFilePath(mediaID)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(filePath)
	if err != nil {
		return nil, err
	}
	if set := h.previews.cachedSet(mediaID, filePath, info); set != nil {
		return set, nil
	}
	probe, ok := h.loadCachedProbe(mediaID, filePath)
	if !ok {
		probe, err = ProbeTracks(filePath)
		if err != nil {
			return nil, err
		}
		h.persistProbe(mediaID, filePath, probe)
	}
	duration := probe.Duration
	if duration <= 0 {
		var stored float64
		_ = h.db.QueryRow("SELECT COALESCE(duration, 0) FROM medias WHERE id = ?", mediaID).Scan(&stored)
		duration = stored
	}
	if duration <= 0 {
		return nil, errors.New("unknown duration")
	}
	set := newPreviewSet(h.previews.root, mediaID, filePath, info, probe, duration)
	h.previews.rememberSet(set)
	return set, nil
}

// PreviewManifest answers POST /api/v1/media/:id/previews with the spacing of
// the stills, and starts filling them in behind the viewer.
//
// The client calls it once the first frame is on screen. Nothing is generated
// before that, so the stills cannot slow down the start of playback.
func (h *Handler) PreviewManifest(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	writeCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, "invalid media id", http.StatusBadRequest)
		return
	}
	w, allowed := playbackauth.Protect(w, r, h.tickets, mediaID)
	if !allowed {
		return
	}
	set, err := h.previewSetFor(mediaID)
	if err != nil {
		log.Printf("previews: media %d: %v", mediaID, err)
		http.Error(w, "previews unavailable", http.StatusNotFound)
		return
	}
	if set.manifest.Count > 0 {
		h.previews.warm(set, playbackauth.Digest(r.URL.Query().Get("ticket")))
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(set.manifest)
}

// PreviewImage answers GET /api/v1/media/:id/previews/:file, where file is
// "<index>.jpg", extracting the still on the spot when the background pass
// has not reached it yet.
func (h *Handler) PreviewImage(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	writeCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}
	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, "invalid media id", http.StatusBadRequest)
		return
	}
	index, err := strconv.Atoi(strings.TrimSuffix(ps.ByName("file"), ".jpg"))
	if err != nil || index < 0 {
		http.Error(w, "invalid preview index", http.StatusBadRequest)
		return
	}
	w, allowed := playbackauth.Protect(w, r, h.tickets, mediaID)
	if !allowed {
		return
	}
	set, err := h.previewSetFor(mediaID)
	if err != nil {
		http.Error(w, "previews unavailable", http.StatusNotFound)
		return
	}
	if index >= set.manifest.Count {
		http.Error(w, "preview index out of range", http.StatusNotFound)
		return
	}
	path, err := h.previews.ensure(r.Context(), set, index, false)
	if err != nil {
		if r.Context().Err() == nil {
			log.Printf("previews: media %d still %d: %v", mediaID, index, err)
			http.Error(w, "preview extraction failed", http.StatusInternalServerError)
		}
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "preview missing", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	_, _ = w.Write(data)
}
