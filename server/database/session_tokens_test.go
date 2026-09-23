package database

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// TestSessionTokensAreHashedByTheMigration : une base d'avant la migration 13
// garde ses sessions, mais plus aucun jeton en clair.
func TestSessionTokensAreHashedByTheMigration(t *testing.T) {
	registerPragmaHook()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "sessions.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })

	all := migrations
	t.Cleanup(func() { migrations = all })
	migrations = all[:12]
	if err := applyMigrations(db); err != nil {
		t.Fatalf("migrations up to 12: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO users (id, username, password_hash) VALUES (1, 'a', 'x')`); err != nil {
		t.Fatal(err)
	}
	const raw = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if _, err := db.Exec(`INSERT INTO sessions (token, user_id) VALUES (?, 1)`, raw); err != nil {
		t.Fatal(err)
	}

	migrations = all
	if err := applyMigrations(db); err != nil {
		t.Fatalf("migration 13: %v", err)
	}

	var stored string
	if err := db.QueryRow(`SELECT token FROM sessions WHERE user_id = 1`).Scan(&stored); err != nil {
		t.Fatalf("the session must survive the migration: %v", err)
	}
	if stored == raw {
		t.Fatal("the token is still stored in clear")
	}
	if stored != SessionTokenDigest(raw) {
		t.Errorf("stored %q, want the digest of the token the device holds", stored)
	}
}
