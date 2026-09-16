package streaming

import (
	"encoding/binary"
	"errors"
	"io"
)

// MP4 / QuickTime: the sync sample table.
//
// The layout that matters is moov → trak → mdia → minf → stbl, holding stts
// (how long each sample lasts) and stss (which samples are keyframes). stss
// being absent is not missing data: it means every sample is a keyframe, which
// is what an all-intra codec like ProRes or MJPEG produces.

var errMalformedMP4 = errors.New("malformed mp4 box structure")

// mp4Box is one box's payload bounds, header excluded.
type mp4Box struct {
	typ        string
	start, end int64
}

// mp4Boxes walks the boxes laid out between start and end, stopping early when
// visit asks it to.
func mp4Boxes(r io.ReaderAt, start, end int64, visit func(mp4Box) (bool, error)) error {
	for off := start; off+8 <= end; {
		var hdr [16]byte
		if _, err := r.ReadAt(hdr[:8], off); err != nil {
			return err
		}
		size := int64(binary.BigEndian.Uint32(hdr[0:4]))
		typ := string(hdr[4:8])
		header := int64(8)

		switch size {
		case 0:
			// A zero size means "to the end of the enclosing box", which is only
			// legal for the last one.
			size = end - off
		case 1:
			// 64-bit size, for boxes past 4 GB — mdat, in practice.
			if _, err := r.ReadAt(hdr[8:16], off+8); err != nil {
				return err
			}
			large := binary.BigEndian.Uint64(hdr[8:16])
			if large > uint64(end-off) {
				return errMalformedMP4
			}
			size = int64(large)
			header = 16
		}
		if size < header || off+size > end {
			return errMalformedMP4
		}

		stop, err := visit(mp4Box{typ: typ, start: off + header, end: off + size})
		if err != nil || stop {
			return err
		}
		off += size
	}
	return nil
}

// mp4Child finds one box directly inside another.
func mp4Child(r io.ReaderAt, parent mp4Box, typ string) (mp4Box, bool, error) {
	var found mp4Box
	ok := false
	err := mp4Boxes(r, parent.start, parent.end, func(b mp4Box) (bool, error) {
		if b.typ == typ {
			found, ok = b, true
			return true, nil
		}
		return false, nil
	})
	return found, ok, err
}

// mp4Descend follows a chain of single children, which is how every table this
// needs is addressed.
func mp4Descend(r io.ReaderAt, from mp4Box, path ...string) (mp4Box, bool, error) {
	current := from
	for _, typ := range path {
		next, ok, err := mp4Child(r, current, typ)
		if err != nil || !ok {
			return mp4Box{}, false, err
		}
		current = next
	}
	return current, true, nil
}

func mp4KeyframeTimes(r io.ReaderAt, size int64) ([]float64, error) {
	moov, ok, err := mp4FindMoov(r, size)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errNoIndex
	}

	var times []float64
	found := false
	err = mp4Boxes(r, moov.start, moov.end, func(trak mp4Box) (bool, error) {
		if trak.typ != "trak" {
			return false, nil
		}
		got, ok, err := mp4TrakKeyframeTimes(r, trak)
		if err != nil {
			return true, err
		}
		if ok {
			times, found = got, true
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, errNoIndex
	}
	return times, nil
}

// mp4FindMoov locates the movie header, wherever the muxer put it.
//
// A file written without +faststart carries moov after mdat, which is exactly
// the case AnalyzeStreamingFile already warns about — so it has to be found by
// walking rather than assumed to be near the front.
func mp4FindMoov(r io.ReaderAt, size int64) (mp4Box, bool, error) {
	var moov mp4Box
	ok := false
	err := mp4Boxes(r, 0, size, func(b mp4Box) (bool, error) {
		if b.typ == "moov" {
			moov, ok = b, true
			return true, nil
		}
		return false, nil
	})
	return moov, ok, err
}

// mp4TrakKeyframeTimes answers for one track, reporting ok=false for the tracks
// that are not the video one so the caller keeps looking.
func mp4TrakKeyframeTimes(r io.ReaderAt, trak mp4Box) ([]float64, bool, error) {
	mdia, ok, err := mp4Child(r, trak, "mdia")
	if err != nil || !ok {
		return nil, false, err
	}

	video, err := mp4IsVideoTrack(r, mdia)
	if err != nil || !video {
		return nil, false, err
	}

	timescale, err := mp4Timescale(r, mdia)
	if err != nil || timescale == 0 {
		return nil, false, err
	}

	stbl, ok, err := mp4Descend(r, mdia, "minf", "stbl")
	if err != nil || !ok {
		return nil, false, err
	}

	stts, ok, err := mp4Child(r, stbl, "stts")
	if err != nil || !ok {
		return nil, false, err
	}
	durations, err := mp4ReadSTTS(r, stts)
	if err != nil {
		return nil, false, err
	}

	// No stss at all means every sample is a sync sample.
	var syncs []uint32
	if stss, ok, err := mp4Child(r, stbl, "stss"); err != nil {
		return nil, false, err
	} else if ok {
		if syncs, err = mp4ReadSTSS(r, stss); err != nil {
			return nil, false, err
		}
	}

	return mp4SyncTimes(durations, syncs, timescale), true, nil
}

// mp4IsVideoTrack reads the handler type, the only thing that distinguishes a
// video track from the audio, subtitle and timecode tracks beside it.
func mp4IsVideoTrack(r io.ReaderAt, mdia mp4Box) (bool, error) {
	hdlr, ok, err := mp4Child(r, mdia, "hdlr")
	if err != nil || !ok {
		return false, err
	}
	// version+flags (4), pre_defined (4), then the four-character handler type.
	if hdlr.end-hdlr.start < 12 {
		return false, nil
	}
	var buf [12]byte
	if _, err := r.ReadAt(buf[:], hdlr.start); err != nil {
		return false, err
	}
	return string(buf[8:12]) == "vide", nil
}

// mp4Timescale reads the track's ticks per second from the media header.
func mp4Timescale(r io.ReaderAt, mdia mp4Box) (uint32, error) {
	mdhd, ok, err := mp4Child(r, mdia, "mdhd")
	if err != nil || !ok {
		return 0, err
	}
	var version [1]byte
	if _, err := r.ReadAt(version[:], mdhd.start); err != nil {
		return 0, err
	}
	// The creation and modification times are 32-bit in version 0 and 64-bit in
	// version 1, which is the whole reason the offset is not a constant.
	offset := int64(12)
	if version[0] == 1 {
		offset = 20
	}
	if mdhd.start+offset+4 > mdhd.end {
		return 0, nil
	}
	var buf [4]byte
	if _, err := r.ReadAt(buf[:], mdhd.start+offset); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(buf[:]), nil
}

// sttsEntry is a run of samples sharing one duration. Constant frame rate
// collapses a whole film into a single entry.
type sttsEntry struct {
	count uint32
	delta uint32
}

func mp4ReadSTTS(r io.ReaderAt, box mp4Box) ([]sttsEntry, error) {
	count, payload, err := mp4TableHeader(r, box, 8)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, count*8)
	if _, err := r.ReadAt(buf, payload); err != nil {
		return nil, err
	}
	entries := make([]sttsEntry, count)
	for i := range entries {
		entries[i] = sttsEntry{
			count: binary.BigEndian.Uint32(buf[i*8 : i*8+4]),
			delta: binary.BigEndian.Uint32(buf[i*8+4 : i*8+8]),
		}
	}
	return entries, nil
}

func mp4ReadSTSS(r io.ReaderAt, box mp4Box) ([]uint32, error) {
	count, payload, err := mp4TableHeader(r, box, 4)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, count*4)
	if _, err := r.ReadAt(buf, payload); err != nil {
		return nil, err
	}
	syncs := make([]uint32, count)
	for i := range syncs {
		syncs[i] = binary.BigEndian.Uint32(buf[i*4 : i*4+4])
	}
	return syncs, nil
}

// mp4TableHeader validates the shared "version/flags, entry count, entries"
// preamble and returns the entry count with the offset the entries start at.
func mp4TableHeader(r io.ReaderAt, box mp4Box, entrySize int64) (int64, int64, error) {
	if box.end-box.start < 8 {
		return 0, 0, errMalformedMP4
	}
	var head [8]byte
	if _, err := r.ReadAt(head[:], box.start); err != nil {
		return 0, 0, err
	}
	count := int64(binary.BigEndian.Uint32(head[4:8]))
	if count < 0 || count > maxIndexEntries {
		return 0, 0, errNoIndex
	}
	payload := box.start + 8
	if payload+count*entrySize > box.end {
		return 0, 0, errMalformedMP4
	}
	return count, payload, nil
}

// mp4SyncTimes converts sample numbers into seconds.
//
// The times are decode times: presentation order differs by the composition
// offsets in ctts where B-frames are used. That shift is near-constant across a
// stream, so the gap between two keyframes — which is all this measures — comes
// out the same either way, and reading ctts would buy nothing.
func mp4SyncTimes(durations []sttsEntry, syncs []uint32, timescale uint32) []float64 {
	var times []float64
	scale := float64(timescale)
	var sample uint64 // 0-based, as stss counts from 1
	var ticks uint64
	cursor := 0
	walked := 0

	for _, entry := range durations {
		for i := uint32(0); i < entry.count; i++ {
			if walked++; walked > maxSampleWalk {
				return times
			}
			at := float64(ticks) / scale
			if at > gopWindowSeconds {
				return times
			}

			if syncs == nil {
				times = append(times, at)
			} else {
				// stss is sorted, so one cursor covers the whole walk.
				for cursor < len(syncs) && uint64(syncs[cursor]) <= sample {
					cursor++
				}
				if cursor < len(syncs) && uint64(syncs[cursor]) == sample+1 {
					times = append(times, at)
					cursor++
				}
			}

			ticks += uint64(entry.delta)
			sample++

			// A zero duration cannot advance the clock, so the window would
			// never close on a malformed table.
			if entry.delta == 0 && len(times) > maxIndexEntries {
				return times
			}
		}
	}
	return times
}
