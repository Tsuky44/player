package indexer

import (
	"log"
	"os"
	"path/filepath"
	"strings"
)

// maxWalkDepth stops runaway recursion on pathological trees.
const maxWalkDepth = 24

// DVD/Blu-ray folder structures: dozens of VOB/M2TS fragments that are one disc,
// and are not direct-playable anyway.
var discStructureDirNames = map[string]bool{
	"video_ts": true, "audio_ts": true, "bdmv": true, "certificate": true,
	"stream": true, "playlist": true, "clipinf": true, "backup": true,
}

// walkVideoFiles walks a library root and calls fn for every indexable video.
//
// Unlike filepath.Walk it never aborts: an unreadable folder or a broken
// symlink skips that branch and the scan continues, so one bad directory can't
// hide the rest of the library. Directory symlinks are followed (NAS/mergerfs
// layouts rely on them) with a loop guard on resolved paths.
func walkVideoFiles(root string, s section, fn func(path string, info os.FileInfo)) {
	if strings.TrimSpace(root) == "" {
		return
	}
	visited := map[string]bool{}

	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if depth > maxWalkDepth {
			reportError("profondeur maximale atteinte, dossier ignoré: %s", dir)
			return
		}
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			if visited[resolved] {
				return // symlink loop or a folder reachable twice
			}
			visited[resolved] = true
		}

		entries, err := os.ReadDir(dir)
		if err != nil {
			log.Printf("Indexer: cannot read directory %s: %v", dir, err)
			reportError("dossier illisible: %s (%v)", dir, err)
			return
		}
		reportDirSeen(s)

		for _, entry := range entries {
			name := entry.Name()
			path := filepath.Join(dir, name)

			info, err := entry.Info()
			if err != nil || info.Mode()&os.ModeSymlink != 0 {
				// Resolve symlinks (and retry a racing stat) against the target.
				info, err = os.Stat(path)
			}
			if err != nil {
				log.Printf("Indexer: cannot stat %s: %v", path, err)
				reportSkipped(s, path, "fichier inaccessible (lien cassé ou permissions)")
				continue
			}

			if info.IsDir() {
				lower := strings.ToLower(name)
				switch {
				case IsJunkDirName(name):
					// System/hidden folder: silently ignored.
				case discStructureDirNames[lower]:
					reportSkippedDir(s, path, "structure disque DVD/Blu-ray non lisible en direct play")
				case IsExtrasDirName(name):
					reportSkippedDir(s, path, "dossier de bonus (extras/trailers)")
				default:
					walk(path, depth+1)
				}
				continue
			}

			if !IsVideoFile(name) {
				if IsUnplayableImageFile(name) {
					reportSkippedDir(s, path, "image disque (.iso) non lisible en direct play")
				}
				continue
			}
			reportVideoFile(s)

			if IsExtraFileName(name) {
				reportSkipped(s, path, "sample / bande-annonce / bonus")
				continue
			}
			if IsSecondaryMultipartFile(name) {
				reportSkipped(s, path, "partie supplémentaire d'un film multi-fichiers")
				continue
			}
			fn(path, info)
		}
	}

	walk(filepath.Clean(root), 0)
}
