package streaming

import (
	"encoding/binary"
	"errors"
	"os"
)

// Reading keyframe positions out of the container's own index, instead of
// asking ffprobe to demux the file.
//
// Every container that supports seeking already stores where its keyframes are:
// MP4 keeps a sync sample table, Matroska keeps cues. Both are a few tens of
// kilobytes at a known offset. Pulling the answer from there costs one open and
// a handful of seeks, where `ffprobe -show_packets` has to push sixty seconds of
// video through a demuxer — tens to hundreds of megabytes off the disk the
// library lives on, per file, for a number this server only logs.
//
// It is a best-effort fast path: anything unexpected returns errNoIndex and the
// caller falls back to ffprobe, which still handles every format this does not
// parse (TS, AVI, WMV...).

// errNoIndex says the file carries no index this code can read, and that the
// ffprobe path should answer instead. It is never a reason to fail a probe.
var errNoIndex = errors.New("no readable keyframe index")

const (
	// gopWindowSeconds bounds the inspection to the opening of the file.
	//
	// It mirrors ffprobe's `-read_intervals 0%+60` exactly, and deliberately so:
	// two implementations of the same measurement that disagree are worse than
	// a narrow measurement. Widening it is now nearly free — the whole index is
	// already in hand — but it has to be widened on both paths at once.
	gopWindowSeconds = 60.0

	// maxIndexEntries rejects a table too large to be real before allocating for
	// it. A header claiming four million samples is a corrupt file, not a long
	// one, and ffprobe is better placed to survive it.
	maxIndexEntries = 1 << 22

	// maxSampleWalk bounds the walk over the time-to-sample table, which is
	// otherwise driven by counts read straight out of the file.
	maxSampleWalk = 1 << 22
)

// keyframeTimesFromIndex returns the keyframe times, in seconds, found in the
// first gopWindowSeconds of the file.
//
// The format is decided from the magic bytes rather than the extension: a .mkv
// that is really an MP4 is common enough, and misreading one as the other would
// produce a confidently wrong number rather than a fallback.
func keyframeTimesFromIndex(path string) ([]float64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := info.Size()

	var head [12]byte
	if _, err := f.ReadAt(head[:], 0); err != nil {
		return nil, errNoIndex
	}
	switch {
	case binary.BigEndian.Uint32(head[0:4]) == ebmlMagic:
		return matroskaKeyframeTimes(f, size)
	case string(head[4:8]) == "ftyp":
		return mp4KeyframeTimes(f, size)
	}
	return nil, errNoIndex
}

// maxGapSeconds is the largest interval between consecutive keyframes.
//
// Fewer than two keyframes is not a zero-length GOP, it is an unanswerable
// question, and 0 is how both paths say so.
func maxGapSeconds(times []float64) float64 {
	if len(times) < 2 {
		return 0
	}
	max := 0.0
	for i := 1; i < len(times); i++ {
		if gap := times[i] - times[i-1]; gap > max {
			max = gap
		}
	}
	return max
}
