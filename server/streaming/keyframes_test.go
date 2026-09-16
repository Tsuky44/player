package streaming

import (
	"bytes"
	"encoding/binary"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// --- MP4 fixtures, built by hand so the expected answer is arithmetic rather
// --- than whatever the local FFmpeg happens to produce.

func u32(v uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return b
}

func box(typ string, parts ...[]byte) []byte {
	payload := bytes.Join(parts, nil)
	out := append(u32(uint32(len(payload)+8)), []byte(typ)...)
	return append(out, payload...)
}

func mp4Trak(handler string, timescale uint32, durations []sttsEntry, syncs []uint32) []byte {
	hdlr := box("hdlr", make([]byte, 8), []byte(handler))
	mdhd := box("mdhd", make([]byte, 12), u32(timescale), u32(0))

	sttsPayload := [][]byte{u32(0), u32(uint32(len(durations)))}
	for _, e := range durations {
		sttsPayload = append(sttsPayload, u32(e.count), u32(e.delta))
	}
	stbl := [][]byte{box("stts", sttsPayload...)}

	if syncs != nil {
		stssPayload := [][]byte{u32(0), u32(uint32(len(syncs)))}
		for _, s := range syncs {
			stssPayload = append(stssPayload, u32(s))
		}
		stbl = append(stbl, box("stss", stssPayload...))
	}

	return box("trak", box("mdia", hdlr, mdhd, box("minf", box("stbl", stbl...))))
}

func mp4File(traks ...[]byte) []byte {
	ftyp := box("ftyp", []byte("isom"), u32(512))
	return append(ftyp, box("moov", traks...)...)
}

func writeTemp(t *testing.T, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func keyframeTimes(t *testing.T, path string) []float64 {
	t.Helper()
	times, err := keyframeTimesFromIndex(path)
	if err != nil {
		t.Fatalf("keyframeTimesFromIndex(%s): %v", filepath.Base(path), err)
	}
	return times
}

func wantTimes(t *testing.T, got, want []float64) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d keyframes %v, want %d %v", len(got), got, len(want), want)
	}
	for i := range want {
		if math.Abs(got[i]-want[i]) > 1e-6 {
			t.Fatalf("keyframe %d = %v, want %v (all: %v)", i, got[i], want[i], got)
		}
	}
}

// 25 fps, one keyframe every 50 samples: the two-second GOP this is meant to
// report.
func TestMP4SyncSampleTable(t *testing.T) {
	data := mp4File(mp4Trak("vide", 1000, []sttsEntry{{count: 1500, delta: 40}}, []uint32{1, 51, 101, 151}))
	times := keyframeTimes(t, writeTemp(t, "gop.mp4", data))
	wantTimes(t, times, []float64{0, 2, 4, 6})
	if gap := maxGapSeconds(times); gap != 2 {
		t.Fatalf("max gap = %v, want 2", gap)
	}
}

// No stss means every sample is a keyframe, which is what all-intra codecs
// produce. Reading it as "no keyframes" would report a GOP of zero.
func TestMP4WithoutSyncTableTreatsEverySampleAsKeyframe(t *testing.T) {
	data := mp4File(mp4Trak("vide", 1000, []sttsEntry{{count: 10, delta: 40}}, nil))
	times := keyframeTimes(t, writeTemp(t, "intra.mp4", data))
	wantTimes(t, times, []float64{0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.24, 0.28, 0.32, 0.36})
	if gap := maxGapSeconds(times); math.Abs(gap-0.04) > 1e-9 {
		t.Fatalf("max gap = %v, want 0.04", gap)
	}
}

// The audio track carries its own stts and stss-less stbl. Reading the first
// track rather than the video one would report the audio's frame timing.
func TestMP4SkipsNonVideoTracks(t *testing.T) {
	audio := mp4Trak("soun", 48000, []sttsEntry{{count: 1000, delta: 1024}}, nil)
	video := mp4Trak("vide", 1000, []sttsEntry{{count: 500, delta: 40}}, []uint32{1, 26, 51})
	times := keyframeTimes(t, writeTemp(t, "av.mp4", mp4File(audio, video)))
	wantTimes(t, times, []float64{0, 1, 2})
}

// A variable frame rate track spreads over several stts entries, and the sample
// a keyframe number refers to depends on every entry before it.
func TestMP4VariableFrameRate(t *testing.T) {
	// 10 samples at 0.1s, then 10 at 0.5s. Keyframes at samples 1, 11 and 16.
	durations := []sttsEntry{{count: 10, delta: 100}, {count: 10, delta: 500}}
	data := mp4File(mp4Trak("vide", 1000, durations, []uint32{1, 11, 16}))
	times := keyframeTimes(t, writeTemp(t, "vfr.mp4", data))
	wantTimes(t, times, []float64{0, 1, 3.5})
}

// Anything past the window is not read, so the two implementations of this
// measurement keep agreeing.
func TestMP4StopsAtTheWindow(t *testing.T) {
	var syncs []uint32
	for i := uint32(0); i < 100; i++ {
		syncs = append(syncs, i*25+1) // one per second
	}
	data := mp4File(mp4Trak("vide", 1000, []sttsEntry{{count: 2500, delta: 40}}, syncs))
	times := keyframeTimes(t, writeTemp(t, "long.mp4", data))
	if len(times) != 61 { // 0s through 60s inclusive
		t.Fatalf("got %d keyframes, want 61 within the %.0fs window", len(times), gopWindowSeconds)
	}
	if last := times[len(times)-1]; last > gopWindowSeconds {
		t.Fatalf("last keyframe at %v, past the %.0fs window", last, gopWindowSeconds)
	}
}

// A file written without +faststart carries moov after the media data — the
// case AnalyzeStreamingFile warns about, so it has to be parsed, not skipped.
func TestMP4FindsMoovAfterMdat(t *testing.T) {
	ftyp := box("ftyp", []byte("isom"), u32(512))
	mdat := box("mdat", make([]byte, 4096))
	moov := box("moov", mp4Trak("vide", 1000, []sttsEntry{{count: 100, delta: 40}}, []uint32{1, 51}))

	data := append(append(ftyp, mdat...), moov...)
	times := keyframeTimes(t, writeTemp(t, "slow.mp4", data))
	wantTimes(t, times, []float64{0, 2})
}

// mdat past 4 GB uses the 64-bit size form, and misreading its header would
// walk into the middle of the media data.
func TestMP4Handles64BitBoxSize(t *testing.T) {
	ftyp := box("ftyp", []byte("isom"), u32(512))

	payload := make([]byte, 64)
	large := append(u32(1), []byte("mdat")...)
	size := make([]byte, 8)
	binary.BigEndian.PutUint64(size, uint64(len(payload)+16))
	large = append(append(large, size...), payload...)

	moov := box("moov", mp4Trak("vide", 1000, []sttsEntry{{count: 100, delta: 40}}, []uint32{1, 51}))
	times := keyframeTimes(t, writeTemp(t, "big.mp4", append(append(ftyp, large...), moov...)))
	wantTimes(t, times, []float64{0, 2})
}

// --- Matroska

func ebmlVIntSize(n int) []byte {
	// Always the eight-byte form: legal, and it keeps the builder from having to
	// pick a width.
	out := make([]byte, 8)
	out[0] = 0x01
	binary.BigEndian.PutUint64(out, uint64(n))
	out[0] = 0x01
	return out
}

func ebmlEl(id []byte, parts ...[]byte) []byte {
	payload := bytes.Join(parts, nil)
	out := append(append([]byte{}, id...), ebmlVIntSize(len(payload))...)
	return append(out, payload...)
}

func ebmlNum(v uint64) []byte {
	out := make([]byte, 8)
	binary.BigEndian.PutUint64(out, v)
	return out
}

// matroskaFile assembles a segment with one video track and the given cue times
// in milliseconds.
func matroskaFile(trackNumber uint64, cueMillis []uint64, seekHead []byte) []byte {
	header := ebmlEl([]byte{0x1A, 0x45, 0xDF, 0xA3}, []byte{0x42, 0x86, 0x81, 0x01})

	info := ebmlEl([]byte{0x15, 0x49, 0xA9, 0x66},
		ebmlEl([]byte{0x2A, 0xD7, 0xB1}, ebmlNum(defaultTimestampScale)))

	tracks := ebmlEl([]byte{0x16, 0x54, 0xAE, 0x6B},
		ebmlEl([]byte{0xAE},
			ebmlEl([]byte{0xD7}, ebmlNum(trackNumber)),
			ebmlEl([]byte{0x83}, ebmlNum(trackTypeVideo)),
		))

	var points [][]byte
	for _, ms := range cueMillis {
		points = append(points, ebmlEl([]byte{0xBB},
			ebmlEl([]byte{0xB3}, ebmlNum(ms)),
			ebmlEl([]byte{0xB7}, ebmlEl([]byte{0xF7}, ebmlNum(trackNumber))),
		))
	}
	cues := ebmlEl([]byte{0x1C, 0x53, 0xBB, 0x6B}, points...)

	// A cluster stands in for the media data the cues have to be found past.
	cluster := ebmlEl([]byte{0x1F, 0x43, 0xB6, 0x75}, make([]byte, 256))

	children := [][]byte{}
	if seekHead != nil {
		children = append(children, seekHead)
	}
	children = append(children, info, tracks, cluster, cues)

	return append(header, ebmlEl([]byte{0x18, 0x53, 0x80, 0x67}, children...)...)
}

func TestMatroskaCues(t *testing.T) {
	data := matroskaFile(1, []uint64{0, 2000, 4000, 7000}, nil)
	times := keyframeTimes(t, writeTemp(t, "cues.mkv", data))
	wantTimes(t, times, []float64{0, 2, 4, 7})
	if gap := maxGapSeconds(times); gap != 3 {
		t.Fatalf("max gap = %v, want 3", gap)
	}
}

func TestMatroskaStopsAtTheWindow(t *testing.T) {
	var cues []uint64
	for i := uint64(0); i < 120; i++ {
		cues = append(cues, i*1000)
	}
	times := keyframeTimes(t, writeTemp(t, "long.mkv", matroskaFile(1, cues, nil)))
	if len(times) != 61 {
		t.Fatalf("got %d cues, want 61 within the %.0fs window", len(times), gopWindowSeconds)
	}
}

// A seek head is an optimisation, and a wrong one must cost accuracy nothing.
// Files edited in place by a tool that did not rewrite it are the real case.
func TestMatroskaIgnoresStaleSeekHead(t *testing.T) {
	stale := ebmlEl([]byte{0x11, 0x4D, 0x9B, 0x74},
		ebmlEl([]byte{0x4D, 0xBB},
			ebmlEl([]byte{0x53, 0xAB}, []byte{0x1C, 0x53, 0xBB, 0x6B}), // SeekID: Cues
			ebmlEl([]byte{0x53, 0xAC}, ebmlNum(7)),                     // nonsense position
		))

	data := matroskaFile(1, []uint64{0, 2000, 4000}, stale)
	times := keyframeTimes(t, writeTemp(t, "stale.mkv", data))
	wantTimes(t, times, []float64{0, 2, 4})
}

// Cue points for the audio track must not be counted as video keyframes.
func TestMatroskaIgnoresOtherTracksCues(t *testing.T) {
	video := ebmlEl([]byte{0xBB},
		ebmlEl([]byte{0xB3}, ebmlNum(0)),
		ebmlEl([]byte{0xB7}, ebmlEl([]byte{0xF7}, ebmlNum(1))),
	)
	audio := ebmlEl([]byte{0xBB},
		ebmlEl([]byte{0xB3}, ebmlNum(1000)),
		ebmlEl([]byte{0xB7}, ebmlEl([]byte{0xF7}, ebmlNum(2))),
	)
	videoLate := ebmlEl([]byte{0xBB},
		ebmlEl([]byte{0xB3}, ebmlNum(3000)),
		ebmlEl([]byte{0xB7}, ebmlEl([]byte{0xF7}, ebmlNum(1))),
	)

	header := ebmlEl([]byte{0x1A, 0x45, 0xDF, 0xA3}, []byte{0x42, 0x86, 0x81, 0x01})
	info := ebmlEl([]byte{0x15, 0x49, 0xA9, 0x66},
		ebmlEl([]byte{0x2A, 0xD7, 0xB1}, ebmlNum(defaultTimestampScale)))
	tracks := ebmlEl([]byte{0x16, 0x54, 0xAE, 0x6B},
		ebmlEl([]byte{0xAE},
			ebmlEl([]byte{0xD7}, ebmlNum(2)),
			ebmlEl([]byte{0x83}, ebmlNum(2)), // audio
		),
		ebmlEl([]byte{0xAE},
			ebmlEl([]byte{0xD7}, ebmlNum(1)),
			ebmlEl([]byte{0x83}, ebmlNum(trackTypeVideo)),
		))
	cues := ebmlEl([]byte{0x1C, 0x53, 0xBB, 0x6B}, video, audio, videoLate)
	segment := ebmlEl([]byte{0x18, 0x53, 0x80, 0x67}, info, tracks, cues)

	times := keyframeTimes(t, writeTemp(t, "mixed.mkv", append(header, segment...)))
	wantTimes(t, times, []float64{0, 3})
}

// --- Dispatch and fallback

// The format is decided from the magic bytes, because a .mkv that is really an
// MP4 is common and reading one as the other would give a confident wrong
// answer instead of a fallback.
func TestFormatComesFromMagicNotExtension(t *testing.T) {
	data := mp4File(mp4Trak("vide", 1000, []sttsEntry{{count: 100, delta: 40}}, []uint32{1, 51}))
	times := keyframeTimes(t, writeTemp(t, "actually.mkv", data))
	wantTimes(t, times, []float64{0, 2})
}

func TestUnreadableContainersFallBack(t *testing.T) {
	for name, data := range map[string][]byte{
		"transport.ts": bytes.Repeat([]byte{0x47, 0x40, 0x00, 0x10}, 64),
		"legacy.avi":   append([]byte("RIFF\x00\x00\x00\x00AVI LIST"), make([]byte, 64)...),
		"truncated.mp4": func() []byte {
			d := mp4File(mp4Trak("vide", 1000, []sttsEntry{{count: 10, delta: 40}}, []uint32{1}))
			return d[:len(d)/2]
		}(),
		"empty.mp4": {},
	} {
		if _, err := keyframeTimesFromIndex(writeTemp(t, name, data)); err == nil {
			t.Errorf("%s: parsed successfully, want a fallback to ffprobe", name)
		}
	}
}

// An unanswerable measurement is reported as zero by both paths, and a single
// keyframe cannot define an interval.
func TestMaxGapNeedsTwoKeyframes(t *testing.T) {
	if gap := maxGapSeconds(nil); gap != 0 {
		t.Errorf("maxGapSeconds(nil) = %v, want 0", gap)
	}
	if gap := maxGapSeconds([]float64{4}); gap != 0 {
		t.Errorf("maxGapSeconds(one) = %v, want 0", gap)
	}
	if gap := maxGapSeconds([]float64{0, 1, 9, 10}); gap != 8 {
		t.Errorf("maxGapSeconds = %v, want 8", gap)
	}
}

// TestMatchesFFprobeOnRealFiles is the one that matters: the container index and
// the demuxer must agree, because the index path silently replaces the other.
//
// It needs FFmpeg to produce the files, so it skips where there is none rather
// than failing a build that has no reason to care.
func TestMatchesFFprobeOnRealFiles(t *testing.T) {
	if testing.Short() {
		t.Skip("generates media with ffmpeg")
	}
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	if _, err := exec.LookPath("ffprobe"); err != nil {
		t.Skip("ffprobe not installed")
	}

	dir := t.TempDir()
	cases := []struct {
		name string
		args []string
		gop  float64
	}{
		{"gop2s.mp4", []string{"-c:v", "libx264", "-g", "50", "-pix_fmt", "yuv420p"}, 2},
		{"gop2s.mkv", []string{"-c:v", "libx264", "-g", "50", "-pix_fmt", "yuv420p"}, 2},
		{"gop2s.mov", []string{"-c:v", "libx264", "-g", "50", "-pix_fmt", "yuv420p"}, 2},
		{"gop4s.mp4", []string{"-c:v", "libx264", "-g", "100", "-pix_fmt", "yuv420p"}, 4},
		{"faststart.mp4", []string{"-c:v", "libx264", "-g", "50", "-pix_fmt", "yuv420p", "-movflags", "+faststart"}, 2},
		{"allintra.mkv", []string{"-c:v", "mjpeg", "-q:v", "9", "-pix_fmt", "yuvj420p"}, 0.04},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name)
			args := append([]string{
				"-y", "-loglevel", "error",
				"-f", "lavfi", "-i", "testsrc=size=160x120:rate=25", "-t", "14",
			}, tc.args...)
			if out, err := exec.Command("ffmpeg", append(args, path)...).CombinedOutput(); err != nil {
				t.Skipf("ffmpeg could not build %s: %v %s", tc.name, err, out)
			}

			times, err := keyframeTimesFromIndex(path)
			if err != nil {
				t.Fatalf("index unreadable, would have fallen back: %v", err)
			}
			native := maxGapSeconds(times)

			reference, err := probeMaxGOPSeconds(path)
			if err != nil {
				t.Fatalf("ffprobe: %v", err)
			}

			if math.Abs(native-reference) > 1e-3 {
				t.Errorf("index says %.4fs, ffprobe says %.4fs", native, reference)
			}
			if math.Abs(native-tc.gop) > 1e-3 {
				t.Errorf("index says %.4fs, the file was encoded with %.4fs", native, tc.gop)
			}
		})
	}
}
