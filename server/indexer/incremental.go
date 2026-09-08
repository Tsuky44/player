package indexer

import (
	"os"

	"project-player/server/database"
	"project-player/server/streamcache"
)

type indexedFile struct {
	id            int
	size, modTime int64
}

// Load once per walk rather than issuing a SQLite query for every file.
// The fingerprint lives in SQLite, so restarting the server preserves it.
func loadIndexedFiles() (map[string]indexedFile, error) {
	rows, err := database.DB.Query(`SELECT id, file_path, COALESCE(file_size,0), COALESCE(file_mod_time,0)
 FROM medias WHERE file_path IS NOT NULL AND file_path != ''`)
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

func (f indexedFile) changed(info os.FileInfo) bool {
	return f.size != info.Size() || f.modTime != info.ModTime().Unix()
}

func (f indexedFile) refresh(info os.FileInfo) error {
	if !f.changed(info) {
		return nil
	}
	// Preserve identity, row ID and watch progress. Probing is queued separately;
	// an unchanged file is never re-probed during the filesystem walk.
	_, err := database.DB.Exec(`UPDATE medias SET file_size=?, file_mod_time=?,
 tracks_json=NULL, probed_at=NULL, gop_seconds=NULL, duration=0,
 intro_start=0, intro_end=0, outro_start=0, outro_end=0 WHERE id=?`, info.Size(), info.ModTime().Unix(), f.id)
	if err == nil {
		streamcache.Global().Invalidate(f.id)
	}
	return err
}
