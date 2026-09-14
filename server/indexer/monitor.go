package indexer

import (
	"errors"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"

	"project-player/server/database"
	"project-player/server/models"
)

// The library monitor indexes what arrives in the library as it arrives,
// without a library scan.
//
// A library scan lists every folder and stats every file: on a large library,
// and worse on network storage, that is minutes of I/O to find one new episode.
// The monitor instead keeps a map of the library's folders and scans only the
// ones that changed. It learns about a change two ways:
//
//   - Filesystem notifications (inotify on Linux). A new file or folder is
//     indexed seconds after it lands. They cost one kernel watch per folder, and
//     they are blind to changes made by another machine on a network share.
//   - A poll of the folders' modification times. Adding, removing or renaming an
//     entry changes its folder's mtime, on local disks as on NFS and SMB, so one
//     stat per folder — no listing, no file stat — finds every changed folder.
//     It is what catches what notifications miss.
//
// A changed folder is scanned shallowly: its own files, plus a deep scan of any
// sub-folder that was not there before and a cleanup of any that disappeared.
// What the scans add is then probed and sent to intro detection by a single
// worker, one file at a time, so a season arriving at once does not start
// twenty ffprobes together.
//
// See docs/adr/0018-surveillance-de-la-mediatheque.md.

// MonitorOptions configures StartLibraryMonitor.
type MonitorOptions struct {
	// Watch turns filesystem notifications on.
	Watch bool
	// PollInterval is the period of the folder poll; 0 turns it off.
	PollInterval time.Duration
	// Roots returns the library roots. It is read again every minute, so a
	// library moved in the settings is followed without a restart.
	Roots func() (moviesDir, seriesDir string)
	// Bootstrap maps the library's folders at start. Leave it off when a library
	// scan runs at startup: the monitor learns the folders from that walk.
	Bootstrap bool
}

const (
	// A folder is scanned once no event touched it for eventQuiet: a copy is a
	// stream of writes, and scanning between two of them finds nothing ready.
	defaultEventQuiet = 3 * time.Second
	// … but never later than maxEventDelay after the first event, so the
	// episodes already copied into a folder still being filled show up.
	defaultMaxEventDelay = time.Minute
	// A new file is indexed once two looks settleTime apart saw the same size
	// and modification time — see fileReady.
	defaultSettleTime = 5 * time.Second
	// A file last modified longer ago than this is complete on first look: a
	// hardlink or a move from the download folder, not a copy in progress.
	defaultSettledAge = 2 * time.Minute

	// The poll stats this many folders, then pauses, so a pass over a large
	// library on network storage is spread out rather than a burst.
	pollStatBurst = 200
	pollPause     = 25 * time.Millisecond

	rootsCheckInterval = time.Minute
)

type dirState struct {
	// modTime is the folder's mtime when it was last listed. Zero means "look
	// again": see recordDir.
	modTime  time.Time
	children []string
}

type scanTarget struct {
	// deep scans sub-folders too; otherwise only the folder's own files.
	deep  bool
	first time.Time
	due   time.Time
}

type fileLook struct {
	size    int64
	modTime time.Time
	at      time.Time
}

type libraryMonitor struct {
	opts MonitorOptions

	eventQuiet    time.Duration
	maxEventDelay time.Duration
	settleTime    time.Duration
	settledAge    time.Duration

	mu        sync.Mutex
	moviesDir string
	seriesDir string
	dirs      map[string]dirState
	observed  map[string]bool
	targets   map[string]*scanTarget
	looks     map[string]fileLook
	watcher   *fsnotify.Watcher
	watchFull bool

	wake chan struct{}
	post *postScanQueue
	stop chan struct{}
}

var (
	monitorMu sync.Mutex
	monitor   *libraryMonitor
)

func activeMonitor() *libraryMonitor {
	monitorMu.Lock()
	defer monitorMu.Unlock()
	return monitor
}

// StartLibraryMonitor starts watching the library. It is meant to be called
// once, before the startup scan, so that scan can hand it the folder map.
func StartLibraryMonitor(opts MonitorOptions) {
	m := newLibraryMonitor(opts)
	if opts.Watch {
		watcher, err := fsnotify.NewWatcher()
		if err != nil {
			log.Printf("Library monitor: filesystem notifications unavailable (%v) — relying on the folder poll", err)
		} else {
			m.watcher = watcher
			go m.watchLoop()
		}
	}

	monitorMu.Lock()
	monitor = m
	monitorMu.Unlock()

	go m.runLoop()
	go m.post.loop()
	go m.maintenanceLoop()
	if opts.Bootstrap {
		go m.bootstrap()
	}

	log.Printf("Library monitor: started (notifications=%t, poll=%v)", m.watcher != nil, opts.PollInterval)
}

func newLibraryMonitor(opts MonitorOptions) *libraryMonitor {
	m := &libraryMonitor{
		opts:          opts,
		eventQuiet:    defaultEventQuiet,
		maxEventDelay: defaultMaxEventDelay,
		settleTime:    defaultSettleTime,
		settledAge:    defaultSettledAge,
		dirs:          map[string]dirState{},
		observed:      map[string]bool{},
		targets:       map[string]*scanTarget{},
		looks:         map[string]fileLook{},
		wake:          make(chan struct{}, 1),
		post:          newPostScanQueue(),
		stop:          make(chan struct{}),
	}
	m.moviesDir, m.seriesDir = cleanRoots(opts.Roots())
	return m
}

func cleanRoots(moviesDir, seriesDir string) (string, string) {
	clean := func(dir string) string {
		if strings.TrimSpace(dir) == "" {
			return ""
		}
		return filepath.Clean(dir)
	}
	return clean(moviesDir), clean(seriesDir)
}

// MonitorStatus is the monitor's state for GET /api/indexer/status.
type MonitorStatus struct {
	Running        bool `json:"running"`
	Notifications  bool `json:"notifications"`
	WatchLimitHit  bool `json:"watch_limit_hit"`
	Folders        int  `json:"folders"`
	PendingFolders int  `json:"pending_folders"`
	PendingFiles   int  `json:"pending_files"`
	PollSeconds    int  `json:"poll_seconds"`
}

// LibraryMonitorStatus reports what the monitor is doing, if it runs.
func LibraryMonitorStatus() MonitorStatus {
	m := activeMonitor()
	if m == nil {
		return MonitorStatus{}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return MonitorStatus{
		Running:        true,
		Notifications:  m.watcher != nil,
		WatchLimitHit:  m.watchFull,
		Folders:        len(m.dirs),
		PendingFolders: len(m.targets),
		PendingFiles:   m.post.len(),
		PollSeconds:    int(m.opts.PollInterval / time.Second),
	}
}

// --- The folder map ----------------------------------------------------------

// recordDir stores what a walk saw of a folder, and watches it.
func (m *libraryMonitor) recordDir(dir string, modTime time.Time, children []string) {
	dir = filepath.Clean(dir)
	// A folder changed in the same second it was listed can keep the mtime we
	// recorded — storage often has one-second resolution. Recording no time
	// makes the next poll list it again rather than trust a listing that may be
	// missing that change.
	if time.Since(modTime) < 2*time.Second {
		modTime = time.Time{}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	_, known := m.dirs[dir]
	m.dirs[dir] = dirState{modTime: modTime, children: children}
	m.observed[dir] = true
	if !known && m.watcher != nil && !m.watchFull {
		if err := m.watcher.Add(dir); err != nil {
			if errors.Is(err, syscall.ENOSPC) || errors.Is(err, syscall.EMFILE) {
				m.watchFull = true
				log.Printf("Library monitor: the system refused more folder watches after %d (%v) — "+
					"folders beyond that are found by the poll only. On Linux, raise fs.inotify.max_user_watches.",
					len(m.dirs), err)
				return
			}
			log.Printf("Library monitor: cannot watch %s: %v", dir, err)
		}
	}
}

// observeShallowDir is recordDir for a shallow scan, which does not descend: a
// sub-folder that is new gets its own deep scan, one that vanished its cleanup.
func (m *libraryMonitor) observeShallowDir(dir string, modTime time.Time, children []string) {
	dir = filepath.Clean(dir)
	m.mu.Lock()
	previous, known := m.dirs[dir]
	var added []string
	for _, child := range children {
		if _, ok := m.dirs[filepath.Clean(child)]; !ok {
			added = append(added, child)
		}
	}
	m.mu.Unlock()

	if known {
		current := make(map[string]bool, len(children))
		for _, child := range children {
			current[filepath.Clean(child)] = true
		}
		for _, child := range previous.children {
			if !current[filepath.Clean(child)] {
				m.enqueue(child, false, 0)
			}
		}
	}
	for _, child := range added {
		m.enqueue(child, true, 0)
	}
	m.recordDir(dir, modTime, children)
}

// forgetDirs drops dir and everything beneath it from the map. The kernel
// removes the watches of deleted folders on its own.
func (m *libraryMonitor) forgetDirs(dir string) {
	dir = filepath.Clean(dir)
	prefix := dir + string(filepath.Separator)
	m.mu.Lock()
	defer m.mu.Unlock()
	for path := range m.dirs {
		if path == dir || strings.HasPrefix(path, prefix) {
			delete(m.dirs, path)
		}
	}
}

// beginObserving starts the record of the folders a library scan walks.
func (m *libraryMonitor) beginObserving() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.observed = map[string]bool{}
}

// pruneUnseenDirs runs after a library scan: a folder it did not walk is gone.
func (m *libraryMonitor) pruneUnseenDirs() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for path := range m.dirs {
		if !m.observed[path] {
			delete(m.dirs, path)
		}
	}
	m.observed = map[string]bool{}
}

func (m *libraryMonitor) isKnownDir(path string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.dirs[path]
	return ok
}

// rootFor returns the library root holding path. The longer root wins, for
// a series root nested in the movies root.
func (m *libraryMonitor) rootFor(path string) (string, section, bool) {
	m.mu.Lock()
	movies, series := m.moviesDir, m.seriesDir
	m.mu.Unlock()

	within := func(root string) bool {
		return root != "" && (path == root || strings.HasPrefix(path, root+string(filepath.Separator)))
	}
	inMovies, inSeries := within(movies), within(series)
	switch {
	case inMovies && inSeries:
		if len(series) >= len(movies) {
			return series, sectionSeries, true
		}
		return movies, sectionMovies, true
	case inSeries:
		return series, sectionSeries, true
	case inMovies:
		return movies, sectionMovies, true
	}
	return "", sectionMovies, false
}

// --- Change detection --------------------------------------------------------

func (m *libraryMonitor) watchLoop() {
	w := m.watcher
	for {
		select {
		case <-m.stop:
			return
		case event, ok := <-w.Events:
			if !ok {
				return
			}
			m.handleEvent(event)
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			if errors.Is(err, fsnotify.ErrEventOverflow) {
				// Events were dropped: the poll is what finds what they carried.
				log.Println("Library monitor: notification queue overflowed — polling the folders now")
				go m.pollOnce()
				continue
			}
			log.Printf("Library monitor: notification error: %v", err)
		}
	}
}

func (m *libraryMonitor) handleEvent(event fsnotify.Event) {
	path := filepath.Clean(event.Name)
	if _, _, ok := m.rootFor(path); !ok {
		return
	}
	name := filepath.Base(path)

	switch {
	case event.Has(fsnotify.Create):
		info, err := os.Stat(path)
		if err == nil && info.IsDir() {
			if IsJunkDirName(name) || IsExtrasDirName(name) || discStructureDirNames[strings.ToLower(name)] {
				return
			}
			m.enqueue(path, true, m.eventQuiet)
			return
		}
		if IsVideoFile(name) {
			m.enqueue(filepath.Dir(path), false, m.eventQuiet)
		}
	case event.Has(fsnotify.Write):
		if IsVideoFile(name) {
			m.enqueue(filepath.Dir(path), false, m.eventQuiet)
		}
	case event.Has(fsnotify.Remove), event.Has(fsnotify.Rename):
		// The old name of a rename; the new one arrives as a Create.
		if IsVideoFile(name) || m.isKnownDir(path) {
			m.enqueue(path, false, m.eventQuiet)
		}
	}
}

func (m *libraryMonitor) maintenanceLoop() {
	rootsTicker := time.NewTicker(rootsCheckInterval)
	defer rootsTicker.Stop()

	var pollC <-chan time.Time
	if m.opts.PollInterval > 0 {
		pollTicker := time.NewTicker(m.opts.PollInterval)
		defer pollTicker.Stop()
		pollC = pollTicker.C
	}

	for {
		select {
		case <-m.stop:
			return
		case <-rootsTicker.C:
			m.checkRoots()
		case <-pollC:
			m.pollOnce()
		}
	}
}

// pollOnce stats every known folder and queues the ones whose mtime moved.
func (m *libraryMonitor) pollOnce() {
	// A library scan is walking everything already, and will hand over a
	// fresh map when it is done.
	if IsScanning() {
		return
	}
	m.checkRoots()

	type polled struct {
		path    string
		modTime time.Time
	}
	m.mu.Lock()
	snapshot := make([]polled, 0, len(m.dirs))
	for path, state := range m.dirs {
		snapshot = append(snapshot, polled{path, state.modTime})
	}
	roots := []string{m.moviesDir, m.seriesDir}
	unmapped := []string{}
	for _, root := range roots {
		if _, ok := m.dirs[root]; root != "" && !ok {
			unmapped = append(unmapped, root)
		}
	}
	// A file that vanished between two looks leaves its first look behind.
	for path, look := range m.looks {
		if time.Since(look.at) > time.Hour {
			delete(m.looks, path)
		}
	}
	m.mu.Unlock()

	for i, dir := range snapshot {
		if i > 0 && i%pollStatBurst == 0 {
			time.Sleep(pollPause)
		}
		info, err := os.Stat(dir.path)
		if err != nil {
			if os.IsNotExist(err) {
				m.enqueue(dir.path, false, 0)
			}
			continue
		}
		if !info.ModTime().Equal(dir.modTime) {
			m.enqueue(dir.path, false, 0)
		}
	}

	// A root that was unreachable when the library was mapped — or was never
	// mapped at all — is walked once it answers.
	for _, root := range unmapped {
		if libraryRootLooksMounted(root) {
			m.enqueue(root, true, 0)
		}
	}
}

// checkRoots follows a library moved in the settings: the old map is dropped,
// and the new roots are walked.
func (m *libraryMonitor) checkRoots() {
	movies, series := cleanRoots(m.opts.Roots())

	m.mu.Lock()
	if movies == m.moviesDir && series == m.seriesDir {
		m.mu.Unlock()
		return
	}
	log.Printf("Library monitor: library roots changed (movies=%s, series=%s)", movies, series)
	m.moviesDir, m.seriesDir = movies, series
	m.dirs = map[string]dirState{}
	m.targets = map[string]*scanTarget{}
	m.looks = map[string]fileLook{}
	m.watchFull = false
	if m.watcher != nil {
		for _, path := range m.watcher.WatchList() {
			_ = m.watcher.Remove(path)
		}
	}
	m.mu.Unlock()

	for _, root := range []string{movies, series} {
		if root != "" {
			m.enqueue(root, true, 0)
		}
	}
}

// bootstrap maps the library's folders without indexing anything, for a
// server started without a library scan.
func (m *libraryMonitor) bootstrap() {
	scanRun.Lock()
	defer scanRun.Unlock()

	m.mu.Lock()
	roots := []struct {
		dir string
		s   section
	}{{m.moviesDir, sectionMovies}, {m.seriesDir, sectionSeries}}
	m.mu.Unlock()

	start := time.Now()
	for _, root := range roots {
		if root.dir == "" {
			continue
		}
		walkVideoFilesWith(root.dir, root.s, walkOptions{onDir: m.recordDir}, func(string, os.FileInfo) {})
	}
	m.mu.Lock()
	count := len(m.dirs)
	m.observed = map[string]bool{}
	m.mu.Unlock()
	log.Printf("Library monitor: mapped %d folder(s) in %v", count, time.Since(start).Round(time.Millisecond))
}

// --- The scan queue ----------------------------------------------------------

// enqueue asks for a scan of path after delay. Asking again for the same
// folder moves its scan back — up to maxEventDelay after the first request —
// and a deep request wins over a shallow one.
func (m *libraryMonitor) enqueue(path string, deep bool, delay time.Duration) {
	path = filepath.Clean(path)
	now := time.Now()

	m.mu.Lock()
	target, ok := m.targets[path]
	if !ok {
		target = &scanTarget{first: now}
		m.targets[path] = target
	}
	target.deep = target.deep || deep
	due := now.Add(delay)
	if limit := target.first.Add(m.maxEventDelay); due.After(limit) {
		due = limit
	}
	target.due = due
	m.mu.Unlock()

	select {
	case m.wake <- struct{}{}:
	default:
	}
}

type dueTarget struct {
	path string
	deep bool
}

// takeDue removes the targets whose time has come, dropping the ones a deep
// scan of an ancestor in the same batch already covers.
func (m *libraryMonitor) takeDue(now time.Time) ([]dueTarget, time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()

	next := time.Hour
	var due []dueTarget
	for path, target := range m.targets {
		if wait := target.due.Sub(now); wait > 0 {
			if wait < next {
				next = wait
			}
			continue
		}
		due = append(due, dueTarget{path, target.deep})
		delete(m.targets, path)
	}
	sort.Slice(due, func(i, j int) bool { return due[i].path < due[j].path })

	var batch []dueTarget
	var deepAncestors []string
	for _, target := range due {
		covered := false
		for _, ancestor := range deepAncestors {
			if strings.HasPrefix(target.path, ancestor+string(filepath.Separator)) {
				covered = true
				break
			}
		}
		if covered {
			continue
		}
		batch = append(batch, target)
		if target.deep {
			deepAncestors = append(deepAncestors, target.path)
		}
	}
	return batch, next
}

func (m *libraryMonitor) runLoop() {
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	for {
		batch, next := m.takeDue(time.Now())
		if len(batch) > 0 {
			m.runBatch(batch)
			continue
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(next)
		select {
		case <-m.stop:
			return
		case <-m.wake:
		case <-timer.C:
		}
	}
}

// batchResult sums what a batch of targeted scans did.
type batchResult struct {
	added, refreshed []int
	removed          int
}

func (m *libraryMonitor) runBatch(batch []dueTarget) {
	scanRun.Lock()
	start := time.Now()
	var result batchResult
	for _, target := range batch {
		m.runTarget(target, &result)
	}
	scanRun.Unlock()

	if n := len(result.added) + len(result.refreshed) + result.removed; n > 0 {
		paths := make([]string, 0, len(batch))
		for _, target := range batch {
			paths = append(paths, target.path)
		}
		log.Printf("Library monitor: %d added, %d changed, %d removed in %v (%s)",
			len(result.added), len(result.refreshed), result.removed,
			time.Since(start).Round(time.Millisecond), strings.Join(paths, ", "))
	}
	m.post.add(result.added)
	m.post.add(result.refreshed)
}

func (m *libraryMonitor) runTarget(target dueTarget, result *batchResult) {
	path, deep := target.path, target.deep
	root, s, ok := m.rootFor(path)
	if !ok {
		return
	}

	info, err := os.Stat(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("Library monitor: cannot stat %s: %v", path, err)
			return
		}
		if path == root {
			// An unmounted library looks like this. Forget its folders so the
			// poll walks it again when it is back; its rows stay.
			m.forgetDirs(path)
			return
		}
		m.forgetDirs(path)
		result.removed += removeMissingUnder(root, path, false, nil)
		return
	}
	if !info.IsDir() {
		// A file replaced under the name it had: its folder is what to look at.
		path, deep = filepath.Dir(path), false
	}

	forgetDirScanCache(path, deep)
	scope := scanScope{root: root, start: path, ready: m.fileReady}
	if deep {
		scope.opts.onDir = m.recordDir
	} else {
		scope.opts.shallow = true
		scope.opts.onDir = m.observeShallowDir
	}

	var outcome *scanOutcome
	if s == sectionSeries {
		outcome = scanSeriesScope(scope)
	} else {
		outcome = scanMovieScope(scope)
	}
	result.added = append(result.added, outcome.added...)
	result.refreshed = append(result.refreshed, outcome.refreshed...)
	result.removed += removeMissingUnder(root, path, !deep, outcome.seen)

	if outcome.deferred {
		m.enqueue(path, deep, m.settleTime)
	}
}

// fileReady decides whether a new or changed file is complete enough to index.
//
// Nothing on disk says a copy is over, so it is inferred: a file whose size and
// modification time did not move between two looks settleTime apart is not
// being written. A file untouched for settledAge passes on first look — that is
// a hardlink or a move from a download folder, complete by construction.
func (m *libraryMonitor) fileReady(path string, info os.FileInfo) bool {
	now := time.Now()
	if now.Sub(info.ModTime()) >= m.settledAge {
		return true
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	look := fileLook{size: info.Size(), modTime: info.ModTime(), at: now}
	previous, ok := m.looks[path]
	if ok && previous.size == look.size && previous.modTime.Equal(look.modTime) {
		if now.Sub(previous.at) >= m.settleTime {
			delete(m.looks, path)
			return true
		}
		return false
	}
	m.looks[path] = look
	return false
}

// --- After a scan ------------------------------------------------------------

// postScanQueue probes what the monitor indexed and sends new episodes to
// intro detection — one file at a time, in the background, so the scans that
// feed it stay quick and the disks are never read by several ffprobes at once.
type postScanQueue struct {
	mu   sync.Mutex
	ids  map[int]bool
	wake chan struct{}
}

func newPostScanQueue() *postScanQueue {
	return &postScanQueue{ids: map[int]bool{}, wake: make(chan struct{}, 1)}
}

func (q *postScanQueue) add(ids []int) {
	if len(ids) == 0 {
		return
	}
	q.mu.Lock()
	for _, id := range ids {
		q.ids[id] = true
	}
	q.mu.Unlock()
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

func (q *postScanQueue) len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.ids)
}

func (q *postScanQueue) take() []int {
	q.mu.Lock()
	defer q.mu.Unlock()
	ids := make([]int, 0, len(q.ids))
	for id := range q.ids {
		ids = append(ids, id)
	}
	q.ids = map[int]bool{}
	sort.Ints(ids)
	return ids
}

func (q *postScanQueue) loop() {
	for range q.wake {
		for ids := q.take(); len(ids) > 0; ids = q.take() {
			processScannedMedia(ids)
		}
	}
}

// processScannedMedia probes the given rows, then runs intro detection for
// the episodes among them, season by season.
func processScannedMedia(ids []int) {
	type row struct {
		id, seasonID    int
		mediaType       string
		title, filePath string
	}
	var rows []row
	for _, id := range ids {
		var r row
		err := database.DB.QueryRow(`SELECT id, type, title, COALESCE(file_path, ''), COALESCE(parent_id, 0)
			FROM medias WHERE id = ?`, id).Scan(&r.id, &r.mediaType, &r.title, &r.filePath, &r.seasonID)
		if err == nil && r.filePath != "" {
			rows = append(rows, r)
		}
	}

	episodesBySeason := map[int][]int{}
	for _, r := range rows {
		info, err := os.Stat(r.filePath)
		if err != nil {
			continue
		}
		ProbeAndPersist(r.id, r.title, r.filePath, info.Size(), info.ModTime())
		if r.mediaType == string(models.TypeEpisode) && r.seasonID > 0 {
			episodesBySeason[r.seasonID] = append(episodesBySeason[r.seasonID], r.id)
		}
	}

	for seasonID, episodeIDs := range episodesBySeason {
		if err := AnalyzeEpisodesPending(seasonID, episodeIDs); err != nil {
			log.Printf("Library monitor: intro detection failed for season %d: %v", seasonID, err)
		}
	}
}
