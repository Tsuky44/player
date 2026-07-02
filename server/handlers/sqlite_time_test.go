package handlers

import (
	"database/sql"
	"testing"
	"time"
)

func TestScanSQLiteTime(t *testing.T) {
	raw := sql.NullString{String: "2026-06-30 14:28:34", Valid: true}
	got := scanSQLiteTime(raw)
	if got.IsZero() {
		t.Fatal("expected parsed time, got zero")
	}
	if got.Year() != 2026 || got.Month() != time.June || got.Day() != 30 {
		t.Fatalf("unexpected time: %v", got)
	}
}
