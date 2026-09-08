package indexer

import (
	"fmt"
	"sync"
	"time"
)

// Reports keep at most this many entries so a huge library can't blow up memory.
const maxReportEntries = 500

// ScanSectionStats counts what happened for one library root during a scan.
type ScanSectionStats struct {
	Root           string `json:"root"`
	Directories    int    `json:"directories"`
	VideoFiles     int    `json:"video_files"`
	Indexed        int    `json:"indexed"`
	AlreadyIndexed int    `json:"already_indexed"`
	Modified       int    `json:"modified"` // subset of already indexed files
	Skipped        int    `json:"skipped"`
	SkippedFolders int    `json:"skipped_folders"`
	Matched        int    `json:"matched"`
	Unmatched      int    `json:"unmatched"`
	Failed         int    `json:"failed"`
}

// SkippedEntry is a file/folder the scan deliberately ignored.
type SkippedEntry struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// UnmatchedEntry is an indexed item that got no confident TMDB match.
type UnmatchedEntry struct {
	Path  string `json:"path"`
	Title string `json:"title"`
	Type  string `json:"type"`
}

// ScanReport explains the gap between "files on disk" and "items in library".
type ScanReport struct {
	Running         bool             `json:"running"`
	StartedAt       time.Time        `json:"started_at"`
	FinishedAt      time.Time        `json:"finished_at"`
	DurationSeconds float64          `json:"duration_seconds"`
	Movies          ScanSectionStats `json:"movies"`
	Series          ScanSectionStats `json:"series"`
	Skipped         []SkippedEntry   `json:"skipped"`
	Unmatched       []UnmatchedEntry `json:"unmatched"`
	Errors          []string         `json:"errors"`
	SkippedTruncate bool             `json:"skipped_truncated"`
	UnmatchedTrunc  bool             `json:"unmatched_truncated"`
}

var (
	reportMu      sync.Mutex
	currentReport ScanReport
	lastReport    ScanReport
)

// LastScanReport returns a copy of the most recent (or in-progress) scan report.
func LastScanReport() ScanReport {
	reportMu.Lock()
	defer reportMu.Unlock()
	if currentReport.Running {
		return currentReport
	}
	return lastReport
}

func beginScanReport(moviesDir, seriesDir string) {
	reportMu.Lock()
	defer reportMu.Unlock()
	currentReport = ScanReport{
		Running:   true,
		StartedAt: time.Now(),
		Movies:    ScanSectionStats{Root: moviesDir},
		Series:    ScanSectionStats{Root: seriesDir},
	}
}

func finishScanReport() {
	reportMu.Lock()
	defer reportMu.Unlock()
	currentReport.Running = false
	currentReport.FinishedAt = time.Now()
	currentReport.DurationSeconds = currentReport.FinishedAt.Sub(currentReport.StartedAt).Seconds()
	lastReport = currentReport
}

// section is the scan-time handle used to record counters for one library root.
type section int

const (
	sectionMovies section = iota
	sectionSeries
)

func (s section) label() string {
	if s == sectionSeries {
		return "series"
	}
	return "movies"
}

func withSection(s section, fn func(*ScanSectionStats)) {
	reportMu.Lock()
	defer reportMu.Unlock()
	if s == sectionSeries {
		fn(&currentReport.Series)
		return
	}
	fn(&currentReport.Movies)
}

func reportDirSeen(s section) {
	withSection(s, func(st *ScanSectionStats) { st.Directories++ })
}

func reportVideoFile(s section) {
	withSection(s, func(st *ScanSectionStats) { st.VideoFiles++ })
}

func reportAlreadyIndexed(s section) {
	withSection(s, func(st *ScanSectionStats) { st.AlreadyIndexed++ })
}

func reportIndexed(s section, matched bool) {
	withSection(s, func(st *ScanSectionStats) {
		st.Indexed++
		if matched {
			st.Matched++
		} else {
			st.Unmatched++
		}
	})
}

func reportFailed(s section) {
	withSection(s, func(st *ScanSectionStats) { st.Failed++ })
}

func reportSkipped(s section, path, reason string) {
	withSection(s, func(st *ScanSectionStats) { st.Skipped++ })
	recordSkipEntry(path, reason)
}

// reportSkippedDir records a whole folder that was not descended into. It is
// counted apart from files so that, per library:
// video_files = indexed + already_indexed + skipped + failed.
func reportSkippedDir(s section, path, reason string) {
	withSection(s, func(st *ScanSectionStats) { st.SkippedFolders++ })
	recordSkipEntry(path, reason)
}

func recordSkipEntry(path, reason string) {
	reportMu.Lock()
	defer reportMu.Unlock()
	if len(currentReport.Skipped) >= maxReportEntries {
		currentReport.SkippedTruncate = true
		return
	}
	currentReport.Skipped = append(currentReport.Skipped, SkippedEntry{Path: path, Reason: reason})
}

func reportUnmatched(path, title, mediaType string) {
	reportMu.Lock()
	defer reportMu.Unlock()
	if len(currentReport.Unmatched) >= maxReportEntries {
		currentReport.UnmatchedTrunc = true
		return
	}
	currentReport.Unmatched = append(currentReport.Unmatched, UnmatchedEntry{
		Path: path, Title: title, Type: mediaType,
	})
}

func reportError(format string, args ...interface{}) {
	reportMu.Lock()
	defer reportMu.Unlock()
	if len(currentReport.Errors) >= maxReportEntries {
		return
	}
	currentReport.Errors = append(currentReport.Errors, fmt.Sprintf(format, args...))
}
