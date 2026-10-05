package installorigin

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

const downloadURL = "https://onyx.example.com/api/downloads/Onyx-1.2.0-android.apk"

// zipOf builds an archive holding the given files.
func zipOf(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for name, content := range files {
		f, err := w.Create(name)
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		if _, err := f.Write([]byte(content)); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return buf.Bytes()
}

// signedAPK inserts an APK Signing Block holding one pair in front of the
// central directory, the way apksigner lays a v2-signed APK out.
func signedAPK(t *testing.T, existingPair []byte) []byte {
	t.Helper()
	plain := zipOf(t, map[string]string{"classes.dex": "dex", "AndroidManifest.xml": "manifest"})
	end, ok := readZipEnd(bytes.NewReader(plain), int64(len(plain)))
	if !ok {
		t.Fatal("fixture zip has no end record")
	}

	blockSize := uint64(len(existingPair) + 24)
	var block bytes.Buffer
	binary.Write(&block, binary.LittleEndian, blockSize)
	block.Write(existingPair)
	binary.Write(&block, binary.LittleEndian, blockSize)
	block.Write(apkSigBlockMagic)

	var apk bytes.Buffer
	apk.Write(plain[:end.cdOffset])
	apk.Write(block.Bytes())
	apk.Write(plain[end.cdOffset:])
	out := apk.Bytes()
	offsetField := len(out) - len(end.eocd) + 16
	binary.LittleEndian.PutUint32(out[offsetField:], uint32(end.cdOffset)+uint32(block.Len()))
	return out
}

func pairOf(id uint32, value string) []byte {
	pair := make([]byte, 12)
	binary.LittleEndian.PutUint64(pair, uint64(4+len(value)))
	binary.LittleEndian.PutUint32(pair[8:], id)
	return append(pair, value...)
}

// signingBlockPairs reads the id → value pairs back out of an APK.
func signingBlockPairs(t *testing.T, apk []byte) map[uint32]string {
	t.Helper()
	end, ok := readZipEnd(bytes.NewReader(apk), int64(len(apk)))
	if !ok {
		t.Fatal("stamped apk has no end record")
	}
	if !bytes.Equal(apk[end.cdOffset-16:end.cdOffset], apkSigBlockMagic) {
		t.Fatal("no signing block in front of the central directory")
	}
	blockSize := int64(binary.LittleEndian.Uint64(apk[end.cdOffset-24:]))
	if got := int64(binary.LittleEndian.Uint64(apk[end.cdOffset-blockSize-8:])); got != blockSize {
		t.Fatalf("leading block size = %d, trailing = %d", got, blockSize)
	}
	pairs := apk[end.cdOffset-blockSize : end.cdOffset-24]
	found := map[uint32]string{}
	for len(pairs) > 0 {
		length := binary.LittleEndian.Uint64(pairs)
		id := binary.LittleEndian.Uint32(pairs[8:])
		found[id] = string(pairs[12 : 8+length])
		pairs = pairs[8+length:]
	}
	return found
}

func stampAll(t *testing.T, content []byte, name string) []byte {
	t.Helper()
	r, size := Stamp(bytes.NewReader(content), int64(len(content)), name, downloadURL)
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read stamped %s: %v", name, err)
	}
	if int64(len(out)) != size {
		t.Fatalf("announced %d bytes, served %d", size, len(out))
	}
	return out
}

func TestStampAPKAddsThePairAndKeepsTheRest(t *testing.T) {
	const v2SignatureID = 0x7109871a
	apk := signedAPK(t, pairOf(v2SignatureID, "signature"))

	stamped := stampAll(t, apk, "Onyx-1.2.0-android.apk")

	pairs := signingBlockPairs(t, stamped)
	if got := pairs[APKBlockID]; got != "HostUrl="+downloadURL+"\n" {
		t.Errorf("origin pair = %q", got)
	}
	if got := pairs[v2SignatureID]; got != "signature" {
		t.Errorf("the existing signature pair was damaged: %q", got)
	}

	// Still a ZIP whose entries read back: that is what the v1 signature and
	// the package installer look at.
	archive, err := zip.NewReader(bytes.NewReader(stamped), int64(len(stamped)))
	if err != nil {
		t.Fatalf("stamped apk is not a zip any more: %v", err)
	}
	if len(archive.File) != 2 {
		t.Errorf("entries = %d, want 2", len(archive.File))
	}

	// Everything the v2 signature covers before the block is byte-identical.
	end, _ := readZipEnd(bytes.NewReader(apk), int64(len(apk)))
	blockStart := end.cdOffset - int64(binary.LittleEndian.Uint64(apk[end.cdOffset-24:])) - 8
	if !bytes.Equal(stamped[:blockStart], apk[:blockStart]) {
		t.Error("the entries in front of the signing block changed")
	}
}

func TestStampIPAAddsTheMarkerInsideTheBundle(t *testing.T) {
	for _, bundle := range []string{"Runner.app", "Onyx TV.app"} {
		ipa := zipOf(t, map[string]string{
			"Payload/" + bundle + "/Info.plist": "plist",
			"Payload/" + bundle + "/Runner":     "binary",
		})

		stamped := stampAll(t, ipa, "Onyx-1.2.0-ios.ipa")

		archive, err := zip.NewReader(bytes.NewReader(stamped), int64(len(stamped)))
		if err != nil {
			t.Fatalf("%s: stamped ipa is not a zip any more: %v", bundle, err)
		}
		if len(archive.File) != 3 {
			t.Fatalf("%s: entries = %d, want 3", bundle, len(archive.File))
		}
		f, err := archive.Open("Payload/" + bundle + "/" + MarkerFile)
		if err != nil {
			t.Fatalf("%s: marker missing: %v", bundle, err)
		}
		// ReadAll checks the CRC on the way out.
		content, err := io.ReadAll(f)
		if err != nil {
			t.Fatalf("%s: read marker: %v", bundle, err)
		}
		if string(content) != "HostUrl="+downloadURL+"\n" {
			t.Errorf("%s: marker = %q", bundle, content)
		}
		plist, err := archive.Open("Payload/" + bundle + "/Info.plist")
		if err != nil {
			t.Fatalf("%s: Info.plist missing: %v", bundle, err)
		}
		if content, _ := io.ReadAll(plist); string(content) != "plist" {
			t.Errorf("%s: Info.plist = %q", bundle, content)
		}
	}
}

// Un installeur qu'on ne sait pas annoter part tel quel, jamais abîmé.
func TestStampLeavesWhatItCannotAnnotateUntouched(t *testing.T) {
	cases := map[string][]byte{
		"Onyx-1.2.0-windows.exe": []byte("MZ not a zip"),
		"Onyx-1.2.0-macos.dmg":   zipOf(t, map[string]string{"a": "b"}),
		// Un APK signé v1 seulement n'a pas de bloc où écrire.
		"Onyx-1.2.0-android.apk": zipOf(t, map[string]string{"classes.dex": "dex"}),
		// Pas de bundle Payload/*.app.
		"Onyx-1.2.0-ios.ipa":  zipOf(t, map[string]string{"README": "x"}),
		"Onyx-1.2.0-tvos.ipa": []byte("truncated"),
	}
	for name, content := range cases {
		if got := stampAll(t, content, name); !bytes.Equal(got, content) {
			t.Errorf("%s: content changed", name)
		}
	}
}

// Une reprise de téléchargement lit au milieu de la vue, à cheval sur les
// octets ajoutés.
func TestStampedViewServesArbitraryRanges(t *testing.T) {
	apk := signedAPK(t, pairOf(1, "signature"))
	whole := stampAll(t, apk, "Onyx.apk")

	r, _ := Stamp(bytes.NewReader(apk), int64(len(apk)), "Onyx.apk", downloadURL)
	for _, offset := range []int64{0, 1, int64(len(whole)) / 2, int64(len(whole)) - 30, int64(len(whole)) - 1} {
		if _, err := r.Seek(offset, io.SeekStart); err != nil {
			t.Fatalf("seek %d: %v", offset, err)
		}
		rest, err := io.ReadAll(r)
		if err != nil {
			t.Fatalf("read from %d: %v", offset, err)
		}
		if !bytes.Equal(rest, whole[offset:]) {
			t.Errorf("range from %d differs from the whole file", offset)
		}
	}
}
