package subtitles

import (
	"strings"

	"project-player/server/database"
)

// Track is an external subtitle exposed to the client via /api/media/:id/tracks.
type Track struct {
	Lang  string `json:"lang"`
	Name  string `json:"name"`
	Ready bool   `json:"ready"`
}

// Register inserts (or refreshes) a subtitle row for a media/language.
func Register(mediaID int, language, title, path string) error {
	_, err := database.DB.Exec(
		`INSERT INTO subtitles (media_id, language, title, path)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(media_id, language)
		 DO UPDATE SET title = excluded.title, path = excluded.path`,
		mediaID, language, title, path,
	)
	return err
}

// List returns every registered subtitle for a media, ready to feed the UI.
func List(mediaID int) ([]Track, error) {
	rows, err := database.DB.Query(
		`SELECT language, title FROM subtitles WHERE media_id = ? ORDER BY language`,
		mediaID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Track
	for rows.Next() {
		var lang, title string
		if err := rows.Scan(&lang, &title); err != nil {
			return nil, err
		}
		name := strings.TrimSpace(title)
		if name == "" {
			name = LanguageLabel(lang)
		}
		out = append(out, Track{Lang: lang, Name: name, Ready: true})
	}
	return out, rows.Err()
}

// Path returns the on-disk .vtt path for a media/language.
func Path(mediaID int, lang string) (string, error) {
	var p string
	err := database.DB.QueryRow(
		`SELECT path FROM subtitles WHERE media_id = ? AND language = ?`,
		mediaID, lang,
	).Scan(&p)
	return p, err
}

// CountForMedia reports how many subtitles are registered for a media.
func CountForMedia(mediaID int) (int, error) {
	var n int
	err := database.DB.QueryRow(
		`SELECT COUNT(*) FROM subtitles WHERE media_id = ?`, mediaID,
	).Scan(&n)
	return n, err
}

// ClearForMedia removes every subtitle row for a media.
func ClearForMedia(mediaID int) error {
	_, err := database.DB.Exec(`DELETE FROM subtitles WHERE media_id = ?`, mediaID)
	return err
}

// PruneExcept deletes subtitle rows whose language is not in keep.
func PruneExcept(mediaID int, keep map[string]bool) error {
	rows, err := database.DB.Query(
		`SELECT language FROM subtitles WHERE media_id = ?`, mediaID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var lang string
		if err := rows.Scan(&lang); err != nil {
			return err
		}
		if !keep[lang] {
			if _, err := database.DB.Exec(
				`DELETE FROM subtitles WHERE media_id = ? AND language = ?`,
				mediaID, lang,
			); err != nil {
				return err
			}
		}
	}
	return rows.Err()
}
