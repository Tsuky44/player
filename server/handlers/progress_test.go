package handlers

import (
	"testing"
	"time"
)

func TestParseClientUpdatedAt_EmptyIsNotAReplay(t *testing.T) {
	if _, ok := parseClientUpdatedAt(""); ok {
		t.Fatal("an absent timestamp must read as a live heartbeat, not a replay")
	}
	if _, ok := parseClientUpdatedAt("   "); ok {
		t.Fatal("whitespace must read as a live heartbeat, not a replay")
	}
}

func TestParseClientUpdatedAt_GarbageIsNotAReplay(t *testing.T) {
	// A client sending something unparseable gets the old behaviour rather than
	// a rejected request: the progress itself is still worth recording.
	if _, ok := parseClientUpdatedAt("hier soir"); ok {
		t.Fatal("an unparseable timestamp must not be treated as a replay")
	}
}

func TestParseClientUpdatedAt_KeepsThePastAndNormalisesToUTC(t *testing.T) {
	parsed, ok := parseClientUpdatedAt("2026-09-01T10:30:00+02:00")
	if !ok {
		t.Fatal("a valid RFC3339 timestamp must be accepted")
	}
	want := time.Date(2026, 9, 1, 8, 30, 0, 0, time.UTC)
	if !parsed.Equal(want) {
		t.Fatalf("expected %v, got %v", want, parsed)
	}
	if parsed.Format(sqliteTimeLayout) != "2026-09-01 08:30:00" {
		t.Fatalf("stored form must match CURRENT_TIMESTAMP, got %q",
			parsed.Format(sqliteTimeLayout))
	}
}

func TestParseClientUpdatedAt_ClampsTheFuture(t *testing.T) {
	// A device with a wrong clock would otherwise pin the row: every later
	// write, replay or heartbeat, would compare as older and be dropped.
	future := time.Now().UTC().Add(48 * time.Hour).Format(time.RFC3339)
	parsed, ok := parseClientUpdatedAt(future)
	if !ok {
		t.Fatal("a future timestamp is still a replay")
	}
	if parsed.After(time.Now().UTC().Add(time.Minute)) {
		t.Fatalf("a future timestamp must be clamped to now, got %v", parsed)
	}
}
