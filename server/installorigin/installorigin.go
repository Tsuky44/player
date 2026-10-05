// Package installorigin glisse dans un installeur l'adresse d'où il est
// téléchargé, pour que l'app s'ouvre sur l'écran de connexion avec l'adresse
// du serveur déjà remplie (ADR-0042).
//
// Windows et macOS n'en ont pas besoin : le système y note lui-même la
// provenance d'un fichier téléchargé. Android et iOS ne notent rien, alors
// c'est le serveur qui l'écrit dans le fichier qu'il sert — sans le copier ni
// le modifier sur le disque : Stamp rend une vue du fichier où quelques
// octets sont intercalés au vol, Range compris.
//
//   - APK : une paire de plus dans l'« APK Signing Block ». Ce bloc n'est
//     couvert par aucune signature (v2, v3), c'est l'emplacement prévu pour
//     ce genre d'annotation. La signature v1 ne voit que les entrées du ZIP,
//     intactes.
//   - IPA : un fichier de plus dans le bundle. L'IPA publié n'est pas signé,
//     l'outil de sideloading signe ce qu'il trouve (ADR-0011).
package installorigin

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"io"
	"path/filepath"
	"strings"
)

// MarkerFile est le nom du marqueur dans le bundle iOS. Il reprend celui que
// l'installeur Windows pose dans ProgramData : même contenu, même lecteur
// côté app.
const MarkerFile = "install-origin.txt"

// APKBlockID identifie la paire d'Onyx dans l'APK Signing Block (« ONYX »).
// L'app relit la même valeur (app/lib/services/install_origin_formats.dart).
const APKBlockID uint32 = 0x4F4E5958

const (
	eocdSignature    = 0x06054b50
	eocdMinSize      = 22
	cdEntrySignature = 0x02014b50
	cdEntryMinSize   = 46
	// Au-delà, le répertoire central n'est pas celui d'un installeur : on ne
	// le charge pas en mémoire sur la foi d'un en-tête.
	maxCentralDirectory = 32 << 20
)

var apkSigBlockMagic = []byte("APK Sig Block 42")

// marker est ce que l'app relit : la ligne HostUrl du Zone.Identifier de
// Windows, pour que les quatre plateformes partagent une seule règle
// d'extraction.
func marker(downloadURL string) []byte {
	return []byte("HostUrl=" + downloadURL + "\n")
}

// Stamp rend le contenu à servir pour l'installeur name : celui de f, avec
// downloadURL glissée dedans quand le format s'y prête.
//
// Tout ce qui sort de l'attendu (format inconnu, ZIP64, APK sans bloc de
// signature) rend le fichier tel quel : mieux vaut un installeur sans adresse
// préremplie qu'un installeur abîmé.
func Stamp(f io.ReaderAt, size int64, name, downloadURL string) (io.ReadSeeker, int64) {
	var stamped *view
	switch strings.ToLower(filepath.Ext(name)) {
	case ".apk":
		stamped = stampAPK(f, size, marker(downloadURL))
	case ".ipa":
		stamped = stampIPA(f, size, marker(downloadURL))
	}
	if stamped == nil {
		return io.NewSectionReader(f, 0, size), size
	}
	return io.NewSectionReader(stamped, 0, stamped.size), stamped.size
}

// zipEnd décrit la fin d'une archive ZIP.
type zipEnd struct {
	// eocd est une copie de l'enregistrement de fin, commentaire compris.
	eocd []byte
	// eocdOffset est sa position dans le fichier.
	eocdOffset int64
	entries    uint16
	cdSize     int64
	cdOffset   int64
}

// readZipEnd localise l'enregistrement de fin. Rend false sur une archive
// ZIP64 ou incohérente.
func readZipEnd(f io.ReaderAt, size int64) (zipEnd, bool) {
	// L'enregistrement est suivi d'un commentaire d'au plus 65535 octets.
	tailLen := int64(eocdMinSize + 0xFFFF)
	if size < tailLen {
		tailLen = size
	}
	tail := make([]byte, tailLen)
	if _, err := f.ReadAt(tail, size-tailLen); err != nil {
		return zipEnd{}, false
	}
	for i := len(tail) - eocdMinSize; i >= 0; i-- {
		if binary.LittleEndian.Uint32(tail[i:]) != eocdSignature {
			continue
		}
		// La signature peut apparaître par hasard dans un commentaire : le vrai
		// enregistrement est celui dont le commentaire finit avec le fichier.
		if int(binary.LittleEndian.Uint16(tail[i+20:])) != len(tail)-i-eocdMinSize {
			continue
		}
		end := zipEnd{
			eocd:       tail[i:],
			eocdOffset: size - tailLen + int64(i),
			entries:    binary.LittleEndian.Uint16(tail[i+10:]),
			cdSize:     int64(binary.LittleEndian.Uint32(tail[i+12:])),
			cdOffset:   int64(binary.LittleEndian.Uint32(tail[i+16:])),
		}
		zip64 := end.entries == 0xFFFF || end.cdSize == 0xFFFFFFFF || end.cdOffset == 0xFFFFFFFF
		if zip64 || end.cdOffset+end.cdSize != end.eocdOffset {
			return zipEnd{}, false
		}
		return end, true
	}
	return zipEnd{}, false
}

// stampAPK ajoute une paire à l'APK Signing Block :
//
//	taille (8) | paires… | [notre paire] | taille (8) | magie (16) | répertoire central
//
// Le bloc grandit, donc le répertoire central recule : son décalage, dans
// l'enregistrement de fin, est le seul autre champ à réécrire. La vérification
// v2 remplace justement ce champ par le début du bloc — qui, lui, ne bouge pas.
func stampAPK(f io.ReaderAt, size int64, value []byte) *view {
	end, ok := readZipEnd(f, size)
	if !ok || end.cdOffset < 32 {
		return nil
	}
	footer := make([]byte, 24)
	if _, err := f.ReadAt(footer, end.cdOffset-24); err != nil {
		return nil
	}
	if !bytes.Equal(footer[8:], apkSigBlockMagic) {
		return nil
	}
	blockSize := binary.LittleEndian.Uint64(footer)
	if blockSize < 24 || blockSize > uint64(end.cdOffset-8) {
		return nil
	}
	blockStart := end.cdOffset - int64(blockSize) - 8
	header := make([]byte, 8)
	if _, err := f.ReadAt(header, blockStart); err != nil || binary.LittleEndian.Uint64(header) != blockSize {
		return nil
	}

	pair := make([]byte, 12, 12+len(value))
	binary.LittleEndian.PutUint64(pair, uint64(4+len(value)))
	binary.LittleEndian.PutUint32(pair[8:], APKBlockID)
	pair = append(pair, value...)

	newCDOffset := end.cdOffset + int64(len(pair))
	if newCDOffset >= 0xFFFFFFFF {
		return nil
	}
	newSize := make([]byte, 8)
	binary.LittleEndian.PutUint64(newSize, blockSize+uint64(len(pair)))
	cdOffsetField := make([]byte, 4)
	binary.LittleEndian.PutUint32(cdOffsetField, uint32(newCDOffset))

	v := &view{}
	v.file(f, 0, blockStart)
	v.bytes(newSize)
	v.file(f, blockStart+8, end.cdOffset-24)
	v.bytes(pair)
	v.bytes(newSize)
	v.file(f, end.cdOffset-16, end.eocdOffset+16)
	v.bytes(cdOffsetField)
	v.file(f, end.eocdOffset+20, size)
	return v
}

// stampIPA ajoute le marqueur au bundle : une entrée non compressée juste
// avant le répertoire central, et sa ligne à la fin de celui-ci.
func stampIPA(f io.ReaderAt, size int64, content []byte) *view {
	end, ok := readZipEnd(f, size)
	if !ok || end.entries == 0xFFFE || end.cdSize > maxCentralDirectory {
		return nil
	}
	directory := make([]byte, end.cdSize)
	if _, err := f.ReadAt(directory, end.cdOffset); err != nil {
		return nil
	}
	bundle := bundlePrefix(directory)
	if bundle == "" {
		return nil
	}
	name := []byte(bundle + MarkerFile)
	checksum := crc32.ChecksumIEEE(content)

	// Version 1.0, aucune option, méthode 0 (stocké), 1er janvier 1980 : une
	// date DOS à zéro désigne un mois 0, que certains outils refusent.
	local := make([]byte, 30, 30+len(name)+len(content))
	binary.LittleEndian.PutUint32(local, 0x04034b50)
	binary.LittleEndian.PutUint16(local[4:], 10)
	binary.LittleEndian.PutUint16(local[12:], 0x21)
	binary.LittleEndian.PutUint32(local[14:], checksum)
	binary.LittleEndian.PutUint32(local[18:], uint32(len(content)))
	binary.LittleEndian.PutUint32(local[22:], uint32(len(content)))
	binary.LittleEndian.PutUint16(local[26:], uint16(len(name)))
	local = append(local, name...)
	local = append(local, content...)

	// « Créé par » Unix (3) avec le mode 0644 : sans lui, le fichier sortirait
	// de l'archive sans aucun droit de lecture.
	entry := make([]byte, cdEntryMinSize, cdEntryMinSize+len(name))
	binary.LittleEndian.PutUint32(entry, cdEntrySignature)
	binary.LittleEndian.PutUint16(entry[4:], 3<<8|10)
	binary.LittleEndian.PutUint16(entry[6:], 10)
	binary.LittleEndian.PutUint16(entry[14:], 0x21)
	binary.LittleEndian.PutUint32(entry[16:], checksum)
	binary.LittleEndian.PutUint32(entry[20:], uint32(len(content)))
	binary.LittleEndian.PutUint32(entry[24:], uint32(len(content)))
	binary.LittleEndian.PutUint16(entry[28:], uint16(len(name)))
	binary.LittleEndian.PutUint32(entry[38:], 0o100644<<16)
	binary.LittleEndian.PutUint32(entry[42:], uint32(end.cdOffset))
	entry = append(entry, name...)

	newCDOffset := end.cdOffset + int64(len(local))
	newCDSize := end.cdSize + int64(len(entry))
	if newCDOffset >= 0xFFFFFFFF || newCDSize >= 0xFFFFFFFF {
		return nil
	}
	eocd := append([]byte(nil), end.eocd...)
	binary.LittleEndian.PutUint16(eocd[8:], end.entries+1)
	binary.LittleEndian.PutUint16(eocd[10:], end.entries+1)
	binary.LittleEndian.PutUint32(eocd[12:], uint32(newCDSize))
	binary.LittleEndian.PutUint32(eocd[16:], uint32(newCDOffset))

	v := &view{}
	v.file(f, 0, end.cdOffset)
	v.bytes(local)
	v.bytes(directory)
	v.bytes(entry)
	v.bytes(eocd)
	return v
}

// bundlePrefix cherche « Payload/Nom.app/ » dans le répertoire central : le
// nom du bundle n'est pas le même sur iPhone et sur Apple TV.
func bundlePrefix(directory []byte) string {
	for len(directory) >= cdEntryMinSize {
		if binary.LittleEndian.Uint32(directory) != cdEntrySignature {
			return ""
		}
		nameLen := int(binary.LittleEndian.Uint16(directory[28:]))
		extraLen := int(binary.LittleEndian.Uint16(directory[30:]))
		commentLen := int(binary.LittleEndian.Uint16(directory[32:]))
		next := cdEntryMinSize + nameLen + extraLen + commentLen
		if next > len(directory) {
			return ""
		}
		name := string(directory[cdEntryMinSize : cdEntryMinSize+nameLen])
		if rest, ok := strings.CutPrefix(name, "Payload/"); ok {
			if app, _, found := strings.Cut(rest, "/"); found && strings.HasSuffix(app, ".app") {
				return "Payload/" + app + "/"
			}
		}
		directory = directory[next:]
	}
	return ""
}

// view est un fichier recomposé : des tranches de l'original et des octets
// en mémoire, bout à bout. Elle ne lit que ce qu'on lui demande, donc une
// reprise de téléchargement (Range) ne relit pas tout l'installeur.
type view struct {
	parts []part
	size  int64
}

type part struct {
	src    io.ReaderAt
	offset int64 // dans src
	start  int64 // dans la vue
	length int64
}

func (v *view) file(f io.ReaderAt, from, to int64) {
	if to > from {
		v.parts = append(v.parts, part{src: f, offset: from, start: v.size, length: to - from})
		v.size += to - from
	}
}

func (v *view) bytes(b []byte) {
	v.file(bytes.NewReader(b), 0, int64(len(b)))
}

func (v *view) ReadAt(p []byte, off int64) (int, error) {
	if off < 0 || off >= v.size {
		return 0, io.EOF
	}
	read := 0
	for _, part := range v.parts {
		if read == len(p) {
			break
		}
		at := off + int64(read)
		if at >= part.start+part.length {
			continue
		}
		within := at - part.start
		chunk := p[read:]
		if remaining := part.length - within; int64(len(chunk)) > remaining {
			chunk = chunk[:remaining]
		}
		n, err := part.src.ReadAt(chunk, part.offset+within)
		read += n
		if n < len(chunk) {
			if err == nil {
				err = io.ErrUnexpectedEOF
			}
			return read, err
		}
	}
	if read < len(p) {
		return read, io.EOF
	}
	return read, nil
}
