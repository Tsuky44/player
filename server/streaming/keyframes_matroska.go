package streaming

import (
	"errors"
	"io"
)

// Matroska / WebM: the cue index.
//
// Cues are what a player seeks with, so they point at keyframes by definition.
// They live in one element, usually written after the clusters, and reaching
// them needs nothing more than skipping each top-level element by the size it
// declares — no cluster is ever read.
//
// The caveat worth knowing: the specification does not require a cue per
// keyframe, and a muxer that writes them sparsely (one every few seconds) would
// make the interval look longer than it is. Every mainstream muxer — mkvmerge,
// FFmpeg — writes one per video keyframe, and the value this feeds is a logged
// hint rather than an input to the streaming decision, so the trade is worth the
// hundreds of megabytes it saves. A file with no cues at all falls back.

var errMalformedEBML = errors.New("malformed ebml structure")

// ebmlMagic opens every EBML document.
const ebmlMagic = 0x1A45DFA3

// The element ids this needs. They are stored with their length marker intact,
// which is why they are compared as the literal bytes on disk.
const (
	idSegment           = 0x18538067
	idInfo              = 0x1549A966
	idTimestampScale    = 0x2AD7B1
	idTracks            = 0x1654AE6B
	idTrackEntry        = 0xAE
	idTrackNumber       = 0xD7
	idTrackType         = 0x83
	idSeekHead          = 0x114D9B74
	idSeek              = 0x4DBB
	idSeekID            = 0x53AB
	idSeekPosition      = 0x53AC
	idCluster           = 0x1F43B675
	idCues              = 0x1C53BB6B
	idCuePoint          = 0xBB
	idCueTime           = 0xB3
	idCueTrackPositions = 0xB7
	idCueTrack          = 0xF7

	// trackTypeVideo is the TrackType value for video.
	trackTypeVideo = 1

	// defaultTimestampScale is the spec's default, in nanoseconds per tick:
	// cue times are in milliseconds unless a file says otherwise.
	defaultTimestampScale = 1000000
)

// ebmlElement is one element's payload bounds, id and header excluded.
type ebmlElement struct {
	id         uint32
	start, end int64
}

// ebmlVInt reads a variable-length integer.
//
// The leading byte's first set bit gives the total length. Ids keep that marker
// because it is part of their identity; sizes have it stripped, and a size
// whose value bits are all set means "unknown", which only a stream being
// written live carries.
func ebmlVInt(r io.ReaderAt, off int64, keepMarker bool) (value uint64, width int64, unknown bool, err error) {
	// Read the widest an integer can be in one go: the length is only known
	// after the first byte, and a second ReadAt per element turned the walk over
	// an all-intra file's cues into thousands of syscalls.
	var buf [8]byte
	n, err := r.ReadAt(buf[:], off)
	if n == 0 {
		return 0, 0, false, err
	}
	b := buf[0]
	if b == 0 {
		return 0, 0, false, errMalformedEBML
	}

	width = 1
	mask := byte(0x80)
	for mask != 0 && b&mask == 0 {
		width++
		mask >>= 1
	}
	if int(width) > n {
		return 0, 0, false, io.ErrUnexpectedEOF
	}

	value = uint64(buf[0])
	if !keepMarker {
		value = uint64(buf[0] &^ mask)
	}
	allOnes := !keepMarker && buf[0]&^mask == mask-1
	for i := int64(1); i < width; i++ {
		value = value<<8 | uint64(buf[i])
		allOnes = allOnes && buf[i] == 0xFF
	}
	return value, width, allOnes, nil
}

// ebmlChildren walks the elements between start and end.
//
// An element of unknown size cannot be skipped, so it ends the walk rather than
// risking a misaligned read of whatever follows.
func ebmlChildren(r io.ReaderAt, start, end int64, visit func(ebmlElement) (bool, error)) error {
	for off := start; off < end; {
		id, idWidth, _, err := ebmlVInt(r, off, true)
		if err != nil {
			return err
		}
		size, sizeWidth, unknown, err := ebmlVInt(r, off+idWidth, false)
		if err != nil {
			return err
		}
		if unknown {
			return errMalformedEBML
		}

		payload := off + idWidth + sizeWidth
		if size > uint64(end-payload) {
			return errMalformedEBML
		}
		element := ebmlElement{id: uint32(id), start: payload, end: payload + int64(size)}

		stop, err := visit(element)
		if err != nil || stop {
			return err
		}
		off = element.end
	}
	return nil
}

// ebmlUint reads an element's unsigned integer payload.
func ebmlUint(r io.ReaderAt, e ebmlElement) (uint64, error) {
	width := e.end - e.start
	if width <= 0 || width > 8 {
		return 0, errMalformedEBML
	}
	buf := make([]byte, width)
	if _, err := r.ReadAt(buf, e.start); err != nil {
		return 0, err
	}
	var value uint64
	for _, b := range buf {
		value = value<<8 | uint64(b)
	}
	return value, nil
}

func matroskaKeyframeTimes(r io.ReaderAt, size int64) ([]float64, error) {
	segment, ok, err := matroskaSegment(r, size)
	if err != nil || !ok {
		if err != nil {
			return nil, err
		}
		return nil, errNoIndex
	}

	scale := uint64(defaultTimestampScale)
	videoTrack := uint64(0)
	var cues ebmlElement
	haveCues := false

	// The seek head names where the top-level elements are, which is the whole
	// point of it. Without it the cues are found by stepping over every cluster
	// in the file: harmless on a normal file with a few dozen, but an all-intra
	// one has a cluster per frame, and 1750 two-read steps cost more than the
	// demux this code exists to avoid.
	if located, ok, err := matroskaSeek(r, segment); err != nil {
		return nil, err
	} else if ok {
		if info, ok := located[idInfo]; ok {
			if got, ok, err := matroskaTimestampScale(r, info); err == nil && ok {
				scale = got
			}
		}
		if tracks, ok := located[idTracks]; ok {
			if got, ok, err := matroskaVideoTrack(r, tracks); err == nil && ok {
				videoTrack = got
			}
		}
		if found, ok := located[idCues]; ok {
			cues, haveCues = found, true
		}
	}

	if haveCues {
		if scale == 0 {
			return nil, errNoIndex
		}
		return matroskaCueTimes(r, cues, videoTrack, scale)
	}

	err = ebmlChildren(r, segment.start, segment.end, func(e ebmlElement) (bool, error) {
		switch e.id {
		case idInfo:
			if got, ok, err := matroskaTimestampScale(r, e); err != nil {
				return true, err
			} else if ok {
				scale = got
			}
		case idTracks:
			if got, ok, err := matroskaVideoTrack(r, e); err != nil {
				return true, err
			} else if ok {
				videoTrack = got
			}
		case idCues:
			cues, haveCues = e, true
		}
		// Clusters are skipped by their declared size, so walking to the end
		// costs a seek each rather than a read.
		return false, nil
	})
	if err != nil {
		return nil, err
	}
	if !haveCues || scale == 0 {
		return nil, errNoIndex
	}

	return matroskaCueTimes(r, cues, videoTrack, scale)
}

// matroskaSegment finds the one top-level element everything else lives in.
func matroskaSegment(r io.ReaderAt, size int64) (ebmlElement, bool, error) {
	var segment ebmlElement
	ok := false
	err := ebmlChildren(r, 0, size, func(e ebmlElement) (bool, error) {
		if e.id == idSegment {
			segment, ok = e, true
			return true, nil
		}
		return false, nil
	})
	return segment, ok, err
}

func matroskaTimestampScale(r io.ReaderAt, info ebmlElement) (uint64, bool, error) {
	var scale uint64
	ok := false
	err := ebmlChildren(r, info.start, info.end, func(e ebmlElement) (bool, error) {
		if e.id != idTimestampScale {
			return false, nil
		}
		value, err := ebmlUint(r, e)
		if err != nil {
			return true, err
		}
		scale, ok = value, true
		return true, nil
	})
	return scale, ok, err
}

// matroskaVideoTrack returns the track number cue points must refer to.
func matroskaVideoTrack(r io.ReaderAt, tracks ebmlElement) (uint64, bool, error) {
	var number uint64
	ok := false
	err := ebmlChildren(r, tracks.start, tracks.end, func(entry ebmlElement) (bool, error) {
		if entry.id != idTrackEntry {
			return false, nil
		}
		var thisNumber, thisType uint64
		if err := ebmlChildren(r, entry.start, entry.end, func(field ebmlElement) (bool, error) {
			switch field.id {
			case idTrackNumber:
				value, err := ebmlUint(r, field)
				if err != nil {
					return true, err
				}
				thisNumber = value
			case idTrackType:
				value, err := ebmlUint(r, field)
				if err != nil {
					return true, err
				}
				thisType = value
			}
			return false, nil
		}); err != nil {
			return true, err
		}
		if thisType == trackTypeVideo {
			number, ok = thisNumber, true
			return true, nil
		}
		return false, nil
	})
	return number, ok, err
}

// matroskaCueTimes reads the cue points belonging to the video track.
//
// A cue with no CueTrackPositions, or a file whose video track could not be
// identified, is taken rather than dropped: a single-track file is the common
// case and refusing it would send it to ffprobe for nothing.
func matroskaCueTimes(r io.ReaderAt, cues ebmlElement, videoTrack, scale uint64) ([]float64, error) {
	var times []float64
	secondsPerTick := float64(scale) / 1e9

	// Cue points are small and numerous — one per keyframe, so an all-intra
	// file has thousands — and each is several nested elements. Pulling the
	// whole table into memory once turns that walk from syscalls into slicing.
	if buffered, ok, err := bufferElement(r, cues); err != nil {
		return nil, err
	} else if ok {
		r = buffered
	}

	err := ebmlChildren(r, cues.start, cues.end, func(point ebmlElement) (bool, error) {
		if point.id != idCuePoint {
			return false, nil
		}
		var tick uint64
		haveTime := false
		matches := videoTrack == 0

		if err := ebmlChildren(r, point.start, point.end, func(field ebmlElement) (bool, error) {
			switch field.id {
			case idCueTime:
				value, err := ebmlUint(r, field)
				if err != nil {
					return true, err
				}
				tick, haveTime = value, true
			case idCueTrackPositions:
				return false, ebmlChildren(r, field.start, field.end, func(inner ebmlElement) (bool, error) {
					if inner.id != idCueTrack {
						return false, nil
					}
					value, err := ebmlUint(r, inner)
					if err != nil {
						return true, err
					}
					if value == videoTrack {
						matches = true
					}
					return true, nil
				})
			}
			return false, nil
		}); err != nil {
			return true, err
		}

		if !haveTime || !matches {
			return false, nil
		}
		at := float64(tick) * secondsPerTick
		if at > gopWindowSeconds {
			// Cues are written in order, so the first one past the window ends
			// the walk.
			return true, nil
		}
		times = append(times, at)
		return len(times) > maxIndexEntries, nil
	})
	if err != nil {
		return nil, err
	}
	return times, nil
}

// maxBufferedElement caps the snapshot in bufferElement. A cue table past this
// is not one this code should be holding in memory.
const maxBufferedElement = 8 << 20

// offsetReaderAt serves a slice of a file under that slice's original offsets,
// so code walking absolute positions does not have to know it was buffered.
type offsetReaderAt struct {
	data []byte
	base int64
}

func (o offsetReaderAt) ReadAt(p []byte, off int64) (int, error) {
	rel := off - o.base
	if rel < 0 || rel > int64(len(o.data)) {
		return 0, io.EOF
	}
	n := copy(p, o.data[rel:])
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

// bufferElement snapshots an element's payload, reporting ok=false when it is
// too large to be worth holding — the caller then keeps reading from the file.
func bufferElement(r io.ReaderAt, e ebmlElement) (io.ReaderAt, bool, error) {
	size := e.end - e.start
	if size <= 0 || size > maxBufferedElement {
		return nil, false, nil
	}
	data := make([]byte, size)
	if _, err := r.ReadAt(data, e.start); err != nil && err != io.EOF {
		return nil, false, err
	}
	return offsetReaderAt{data: data, base: e.start}, true, nil
}

// matroskaSeek reads the seek head into a map of top-level element to position.
//
// Reporting ok=false is not a failure: a file written without a seek head, or
// with one whose entries do not resolve, simply goes back to walking. Every
// offset is validated against the segment before it is trusted, because a stale
// seek head — a file edited in place by a tool that did not rewrite it — points
// into the middle of whatever now occupies that byte.
func matroskaSeek(r io.ReaderAt, segment ebmlElement) (map[uint32]ebmlElement, bool, error) {
	located := map[uint32]ebmlElement{}

	err := ebmlChildren(r, segment.start, segment.end, func(top ebmlElement) (bool, error) {
		// Seek heads sit ahead of the payload, so the first cluster ends the
		// search whether or not anything was found.
		if top.id == idCluster {
			return true, nil
		}
		if top.id != idSeekHead {
			return false, nil
		}
		return false, ebmlChildren(r, top.start, top.end, func(seek ebmlElement) (bool, error) {
			if seek.id != idSeek {
				return false, nil
			}
			var targetID uint32
			var position uint64
			haveID, havePosition := false, false

			if err := ebmlChildren(r, seek.start, seek.end, func(field ebmlElement) (bool, error) {
				switch field.id {
				case idSeekID:
					// SeekID carries the target's id as raw bytes, marker and all.
					value, err := ebmlUint(r, field)
					if err != nil {
						return true, err
					}
					targetID, haveID = uint32(value), true
				case idSeekPosition:
					value, err := ebmlUint(r, field)
					if err != nil {
						return true, err
					}
					position, havePosition = value, true
				}
				return false, nil
			}); err != nil {
				return true, err
			}
			if !haveID || !havePosition {
				return false, nil
			}

			// Positions are relative to the start of the segment's payload.
			at := segment.start + int64(position)
			if at < segment.start || at >= segment.end {
				return false, nil
			}
			element, err := ebmlElementAt(r, at, segment.end)
			if err != nil || element.id != targetID {
				return false, nil
			}
			located[targetID] = element
			return false, nil
		})
	})
	if err != nil {
		return nil, false, nil // a broken seek head is a reason to walk, not to fail
	}
	return located, len(located) > 0, nil
}

// ebmlElementAt reads the element header sitting at a known offset.
func ebmlElementAt(r io.ReaderAt, off, limit int64) (ebmlElement, error) {
	id, idWidth, _, err := ebmlVInt(r, off, true)
	if err != nil {
		return ebmlElement{}, err
	}
	size, sizeWidth, unknown, err := ebmlVInt(r, off+idWidth, false)
	if err != nil {
		return ebmlElement{}, err
	}
	if unknown {
		return ebmlElement{}, errMalformedEBML
	}
	start := off + idWidth + sizeWidth
	if size > uint64(limit-start) {
		return ebmlElement{}, errMalformedEBML
	}
	return ebmlElement{id: uint32(id), start: start, end: start + int64(size)}, nil
}
