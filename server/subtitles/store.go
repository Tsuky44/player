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
	// TypedIndex is the track's position among the container's subtitle streams
	// (the N in 0:s:N), or -1 when it could not be determined. It lets the client
	// pair an embedded track it sees in Direct Play with this canonical entry
	// WITHOUT re-deriving a language code of its own — the two derivations used
	// to disagree for any language outside the table below.
	TypedIndex int `json:"typed_index"`
	// Forced marks a track that only covers foreign dialogue, not the whole film.
	// A file often carries both a full and a forced track for one language; the
	// client needs the flag to avoid silently handing the user the near-empty one.
	Forced bool `json:"forced"`
	// Default marks the track the container itself flags as preferred.
	Default bool `json:"default"`
	// Image marks a bitmap track (PGS/VOBSUB). It has no .vtt: Direct Play renders
	// it natively, and transcoding burns it into the picture. The client needs the
	// flag because selecting one in HLS is the only subtitle change that costs a
	// new session.
	Image bool `json:"image"`
	// Partial is true while only the head of the media has been extracted. The
	// track is usable right away; the client keeps polling and re-attaches once
	// the complete pass lands.
	Partial bool `json:"partial"`
}

// Register inserts (or refreshes) a subtitle row for a media/language.
func Register(mediaID int, language, title, path string, partial bool) error {
	_, err := database.DB.Exec(
		`INSERT INTO subtitles (media_id, language, title, path, partial)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(media_id, language)
		 DO UPDATE SET title = excluded.title, path = excluded.path,
		               partial = excluded.partial`,
		mediaID, language, title, path, boolToInt(partial),
	)
	return err
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// List returns every registered subtitle for a media, ready to feed the UI.
func List(mediaID int) ([]Track, error) {
	rows, err := database.DB.Query(
		`SELECT language, title, partial FROM subtitles WHERE media_id = ? ORDER BY language`,
		mediaID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Track
	for rows.Next() {
		var lang, title string
		var partial int
		if err := rows.Scan(&lang, &title, &partial); err != nil {
			return nil, err
		}
		name := strings.TrimSpace(title)
		if name == "" {
			name = LanguageLabel(lang)
		}
		out = append(out, Track{
			Lang:    lang,
			Name:    name,
			Ready:   true,
			Partial: partial == 1,
			// The DB row has no notion of stream position; Catalog stamps it from
			// the probe when one is available.
			TypedIndex: -1,
		})
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

// CountCompleteForMedia reports how many fully-extracted subtitles a media has.
// Rows left over from a head pass do not count: they still need completing.
func CountCompleteForMedia(mediaID int) (int, error) {
	var n int
	err := database.DB.QueryRow(
		`SELECT COUNT(*) FROM subtitles WHERE media_id = ? AND partial = 0`, mediaID,
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
