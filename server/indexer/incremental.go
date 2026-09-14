package indexer

import (
	"os"
	"path/filepath"
	"strings"

	"project-player/server/database"
	"project-player/server/streamcache"
)

type indexedFile struct {
	id            int
	size, modTime int64
}

// loadIndexedFilesUnder loads the fingerprints of the rows stored beneath dir,
// or only of the ones directly in it when shallow. Once per walk rather than a
// SQLite query for every file, and scoped to the walk: a targeted scan of a
// season folder reads its twenty rows, not the whole library's. The
// fingerprint lives in SQLite, so restarting the server preserves it.
func loadIndexedFilesUnder(dir string, shallow bool) (map[string]indexedFile, error) {
	lower, upper := pathPrefixRange(dir)
	files, err := queryIndexedFiles(`SELECT id, file_path, COALESCE(file_size,0), COALESCE(file_mod_time,0)
 FROM medias WHERE file_path >= ? AND file_path < ?`, lower, upper)
	if err != nil || !shallow {
		return files, err
	}
	for path := range files {
		if strings.Contains(path[len(lower):], "/") {
			delete(files, path)
		}
	}
	return files, nil
}

func queryIndexedFiles(query string, args ...interface{}) (map[string]indexedFile, error) {
	rows, err := database.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	files := make(map[string]indexedFile)
	for rows.Next() {
		var path string
		var f indexedFile
		if err := rows.Scan(&f.id, &path, &f.size, &f.modTime); err != nil {
			return nil, err
		}
		files[path] = f
	}
	return files, rows.Err()
}

// pathPrefixRange bounds the stored paths beneath dir as a half-open range,
// [dir + "/", dir + "0"): '0' is the character after '/', so the range holds
// exactly the paths that continue with a slash. Unlike LIKE, a range is served
// by idx_medias_file_path, and it has no wildcard to escape in a folder name.
func pathPrefixRange(dir string) (lower, upper string) {
	base := strings.TrimSuffix(filepath.ToSlash(filepath.Clean(dir)), "/")
	return base + "/", base + "0"
}

func (f indexedFile) changed(info os.FileInfo) bool {
	return f.size != info.Size() || f.modTime != info.ModTime().Unix()
}

func (f indexedFile) refresh(info os.FileInfo) error {
	if !f.changed(info) {
		return nil
	}
	// Preserve identity, row ID and watch progress. Probing is queued separately;
	// an unchanged file is never re-probed during the filesystem walk.
	// A new file also earns a new attempt at what failed on the old one.
	_, err := database.DB.Exec(`UPDATE medias SET file_size=?, file_mod_time=?,
 tracks_json=NULL, probed_at=NULL, gop_seconds=NULL, duration=0, probe_failed_at=NULL,
 intro_start=0, intro_end=0, outro_start=0, outro_end=0, intro_checked_at=NULL WHERE id=?`, info.Size(), info.ModTime().Unix(), f.id)
	if err == nil {
		streamcache.Global().Invalidate(f.id)
	}
	return err
}
