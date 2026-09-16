package database

import (
	"context"
	"database/sql"
	"path/filepath"
	"sync"
	"testing"
)

// TestPragmasApplyToEveryPooledConnection pins the fix for connections that
// came out of the pool unconfigured.
//
// The pragmas used to be run with DB.Exec, which reaches exactly one
// connection. The other three served queries with foreign_keys off and
// busy_timeout at zero, so a read that landed on one of them during an indexer
// write failed immediately instead of waiting for the writer.
func TestPragmasApplyToEveryPooledConnection(t *testing.T) {
	db, err := InitDB(filepath.Join(t.TempDir(), "pragmas.db"))
	if err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	// Hold every connection open at once, otherwise the pool hands the same
	// already-configured one back for each check and the test proves nothing.
	conns := make([]*sql.Conn, 0, 4)
	for i := 0; i < 4; i++ {
		conn, err := db.Conn(context.Background())
		if err != nil {
			t.Fatalf("Conn %d: %v", i, err)
		}
		conns = append(conns, conn)
	}
	t.Cleanup(func() {
		for _, conn := range conns {
			_ = conn.Close()
		}
	})

	checks := []struct {
		pragma string
		want   int64
	}{
		{"foreign_keys", 1},
		{"busy_timeout", 5000},
		{"cache_size", -32768},
		{"temp_store", 2}, // 2 = MEMORY
	}
	for i, conn := range conns {
		for _, check := range checks {
			var got int64
			if err := conn.QueryRowContext(context.Background(), "PRAGMA "+check.pragma).Scan(&got); err != nil {
				t.Fatalf("conn %d: PRAGMA %s: %v", i, check.pragma, err)
			}
			if got != check.want {
				t.Errorf("conn %d: PRAGMA %s = %d, want %d", i, check.pragma, got, check.want)
			}
		}
	}
}

// TestWALIsEnabled guards the one pragma that lives in the file rather than the
// connection: losing it would serialise every reader behind the indexer.
func TestWALIsEnabled(t *testing.T) {
	db, err := InitDB(filepath.Join(t.TempDir(), "wal.db"))
	if err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	var mode string
	if err := db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil {
		t.Fatalf("PRAGMA journal_mode: %v", err)
	}
	if mode != "wal" {
		t.Errorf("journal_mode = %q, want \"wal\"", mode)
	}
}

// TestConcurrentReadDuringWriteDoesNotFail is the user-visible half of the
// pragma fix: an API read must wait for the indexer's writer, not return
// "database is locked" as a 500.
func TestConcurrentReadDuringWriteDoesNotFail(t *testing.T) {
	db, err := InitDB(filepath.Join(t.TempDir(), "busy.db"))
	if err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create: %v", err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 32)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				if _, err := db.Exec(`INSERT INTO t (v) VALUES (?)`, "x"); err != nil {
					errs <- err
					return
				}
				var count int
				if err := db.QueryRow(`SELECT COUNT(*) FROM t`).Scan(&count); err != nil {
					errs <- err
					return
				}
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent read/write failed: %v", err)
	}
}
