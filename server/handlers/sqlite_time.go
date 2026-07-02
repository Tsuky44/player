package handlers

import (
	"database/sql"
	"time"
)

func scanSQLiteTime(raw sql.NullString) time.Time {
	if !raw.Valid || raw.String == "" {
		return time.Time{}
	}
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05.999999999-07:00",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, raw.String); err == nil {
			return t
		}
	}
	return time.Time{}
}
