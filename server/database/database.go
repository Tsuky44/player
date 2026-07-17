package database

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

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

	// Create tables
	if err := createTables(); err != nil {
		return nil, fmt.Errorf("failed to create tables: %w", err)
	}

	return DB, nil
}

func createTables() error {
	queries := []string{
		// Users Table
		`CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			username TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL
		);`,

		// Medias Table (Hierarchical: Show -> Season -> Episode, or Movie)
		`CREATE TABLE IF NOT EXISTS medias (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			type TEXT NOT NULL CHECK(type IN ('movie', 'show', 'season', 'episode')),
			title TEXT NOT NULL,
			file_path TEXT,
			duration INTEGER DEFAULT 0,
			parent_id INTEGER,
			poster_url TEXT,
			overview TEXT,
			release_date TEXT,
			tmdb_id INTEGER,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (parent_id) REFERENCES medias(id) ON DELETE CASCADE
		);`,

		// Index on parent_id and type for fast lookup
		`CREATE INDEX IF NOT EXISTS idx_medias_parent_id ON medias(parent_id);`,
		`CREATE INDEX IF NOT EXISTS idx_medias_type ON medias(type);`,

		// Migration: Add intro/outro timestamps columns if they don't exist
		`ALTER TABLE medias ADD COLUMN intro_start INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN intro_end INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN outro_start INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN outro_end INTEGER DEFAULT 0;`,
		// Migration: Add imdb_id column for caching TheIntroDB lookups
		`ALTER TABLE medias ADD COLUMN imdb_id TEXT;`,
		// Migration: season/episode numbers for TMDB episode metadata
		`ALTER TABLE medias ADD COLUMN season_number INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN episode_number INTEGER DEFAULT 0;`,
		// Streaming optimization columns
		`ALTER TABLE medias ADD COLUMN file_size INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN tracks_json TEXT;`,
		`ALTER TABLE medias ADD COLUMN probed_at TIMESTAMP;`,
		`ALTER TABLE medias ADD COLUMN file_mod_time INTEGER DEFAULT 0;`,
		`ALTER TABLE medias ADD COLUMN gop_seconds REAL;`,

		// Progressions Table
		`CREATE TABLE IF NOT EXISTS progressions (
			user_id INTEGER NOT NULL,
			media_id INTEGER NOT NULL,
			current_position_seconds INTEGER NOT NULL DEFAULT 0,
			is_finished BOOLEAN NOT NULL DEFAULT 0,
			updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (user_id, media_id),
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
			FOREIGN KEY (media_id) REFERENCES medias(id) ON DELETE CASCADE
		);`,

		// Sessions Table for authentication
		`CREATE TABLE IF NOT EXISTS sessions (
			token TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
		);`,

		// Index on progressions updated_at for "Continue Watching" ordering
		`CREATE INDEX IF NOT EXISTS idx_progressions_updated_at ON progressions(updated_at DESC);`,

		// User-dismissed entries hidden from the home "Continue Watching" row only.
		`CREATE TABLE IF NOT EXISTS continue_watching_hidden (
			user_id INTEGER NOT NULL,
			entry_key TEXT NOT NULL,
			hidden_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (user_id, entry_key),
			FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
		);`,

		// Subtitles Table: pre-extracted external .vtt tracks discovered at scan time.
		`CREATE TABLE IF NOT EXISTS subtitles (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			media_id INTEGER NOT NULL,
			language TEXT NOT NULL,
			title TEXT,
			path TEXT NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(media_id, language),
			FOREIGN KEY (media_id) REFERENCES medias(id) ON DELETE CASCADE
		);`,
		`CREATE INDEX IF NOT EXISTS idx_subtitles_media_id ON subtitles(media_id);`,
	}

	for _, query := range queries {
		if _, err := DB.Exec(query); err != nil {
			// Ignore "duplicate column name" errors from ALTER TABLE migrations
			if strings.Contains(err.Error(), "duplicate column name") {
				continue
			}
			return fmt.Errorf("error executing query [%s]: %w", query, err)
		}
	}

	log.Println("Database tables initialized successfully.")
	return nil
}
