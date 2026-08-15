package database

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

// InitDB initializes the SQLite database, runs migrations, and enables WAL mode
func InitDB(dbPath string) (*sql.DB, error) {
	// Ensure directory exists
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create database directory: %w", err)
	}

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

	// Configure SQLite performance and WAL mode
	pragmas := []string{
		"PRAGMA journal_mode=WAL;",
		"PRAGMA synchronous=NORMAL;",
		"PRAGMA foreign_keys=ON;",
		"PRAGMA busy_timeout=5000;", // 5 seconds wait if DB is locked
	}

	for _, pragma := range pragmas {
		if _, err := DB.Exec(pragma); err != nil {
			return nil, fmt.Errorf("failed to execute pragma (%s): %w", pragma, err)
		}
	}

	log.Println("SQLite database opened successfully with WAL mode enabled.")

	// Bring the schema up to date. See migrations.go.
	if err := applyMigrations(DB); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return DB, nil
}
