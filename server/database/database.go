package database

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"

	"modernc.org/sqlite"
)

var DB *sql.DB

// Path is the file DB was opened from, for the dashboard's storage figures.
var Path string

// DataDir est le dossier où le serveur range tout ce qu'il produit : la base,
// les sous-titres extraits, les aperçus. C'est celui de la base.
//
// Les sous-titres et les aperçus allaient dans un « data » relatif au dossier
// de lancement, qui ne coïncidait avec celui de la base que dans l'image
// Docker. Lancé d'ailleurs, ou avec -db ailleurs, le serveur éparpillait ses
// fichiers là où on l'avait démarré.
func DataDir() string {
	if Path == "" {
		return "data"
	}
	return filepath.Dir(Path)
}

// InitDB initializes the SQLite database, runs migrations, and enables WAL mode
func InitDB(dbPath string) (*sql.DB, error) {
	// Ensure directory exists
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create database directory: %w", err)
	}

	Path = dbPath

	// Every connection in the pool needs the pragmas below, so they are applied
	// from a driver hook rather than with DB.Exec — see registerPragmaHook.
	registerPragmaHook()

	// Open connection
	var err error
	DB, err = sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open sqlite database: %w", err)
	}

	// Set connection limits — WAL allows concurrent readers; never hold open
	// rows while executing another query on the same pool (deadlocks otherwise).
	DB.SetMaxOpenConns(4)
	DB.SetMaxIdleConns(4)

	// Open is lazy: without this the first real query is what would surface a
	// bad path or a failing pragma, from wherever it happened to run.
	if err := DB.Ping(); err != nil {
		return nil, fmt.Errorf("failed to connect to sqlite database: %w", err)
	}

	log.Println("SQLite database opened successfully with WAL mode enabled.")

	// Bring the schema up to date. See migrations.go.
	if err := applyMigrations(DB); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return DB, nil
}

// connectionPragmas are applied to every connection the pool opens.
//
// All but journal_mode are per-connection settings, and the pool holds four
// connections. Running them through DB.Exec — which is what this did — sets
// them on whichever single connection happened to serve that call, so three
// connections out of four ran with foreign_keys off and, worse, busy_timeout
// at zero: a read that landed on one of them while the indexer was writing
// failed instantly with "database is locked" instead of waiting.
//
// journal_mode is persisted in the database file rather than the connection, so
// it is idempotent here and kept for the case of a fresh file.
var connectionPragmas = []string{
	"PRAGMA journal_mode=WAL;",
	"PRAGMA synchronous=NORMAL;",
	"PRAGMA foreign_keys=ON;",
	"PRAGMA busy_timeout=5000;", // 5 seconds wait if DB is locked
	// SQLite ships a 2 MB page cache, small enough that the home screen's list
	// queries re-read the same pages from disk on every request. 32 MB holds
	// the medias table and its indexes for a library of any realistic size, and
	// SQLite only commits the pages it actually touches.
	"PRAGMA cache_size=-32768;", // negative = KiB, so 32 MiB
	// Sorts and temporary indexes — every ORDER BY that cannot use an index —
	// spill to a temp file by default, on the same disk the media streams from.
	"PRAGMA temp_store=MEMORY;",
	// Read pages through mmap instead of a read() per page. Harmless where the
	// driver's VFS does not implement it: the pragma reports back 0 rather than
	// failing, which is why its effect is not asserted.
	"PRAGMA mmap_size=268435456;", // 256 MiB
}

// pragmaHookOnce guards the driver-global registration, which InitDB may reach
// more than once across a test binary.
var pragmaHookOnce sync.Once

func registerPragmaHook() {
	pragmaHookOnce.Do(func() {
		sqlite.RegisterConnectionHook(func(conn sqlite.ExecQuerierContext, _ string) error {
			for _, pragma := range connectionPragmas {
				if _, err := conn.ExecContext(context.Background(), pragma, nil); err != nil {
					return fmt.Errorf("failed to execute pragma (%s): %w", pragma, err)
				}
			}
			return nil
		})
	})
}
