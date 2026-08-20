package database

import (
	"database/sql"
	"fmt"
	"log"
	"strings"
)

// Schema migrations.
//
// The schema used to be a single flat list of statements replayed in full on
// every start, with ALTER TABLE failures filtered by matching on the error
// string. That worked, but it left three real problems: nothing recorded what
// had run, so ordering was implicit and a statement could never be changed once
// shipped; a genuine failure whose message happened to contain "duplicate
// column name" was swallowed; and a half-applied change left no trace.
//
// Now each change is a numbered migration, applied once, inside a transaction,
// and recorded in schema_migrations. Adding a column is a new entry at the
// bottom of the list — never an edit to an existing one, because the installs
// in the wild have already run it.
type migration struct {
	id    int
	name  string
	stmts []string
}

// migrations must stay ordered by id, and ids must never be reused.
var migrations = []migration{
	{
		id:   1,
		name: "baseline",
		// Everything the flat list built, as it stood when migrations were
		// introduced. On an existing install every statement here is a no-op;
		// on a fresh one it builds the whole schema.
		stmts: []string{
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
			`CREATE INDEX IF NOT EXISTS idx_medias_parent_id ON medias(parent_id);`,
			`CREATE INDEX IF NOT EXISTS idx_medias_type ON medias(type);`,

			// Intro/outro timestamps.
			`ALTER TABLE medias ADD COLUMN intro_start INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN intro_end INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN outro_start INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN outro_end INTEGER DEFAULT 0;`,
			// imdb_id caches TheIntroDB lookups.
			`ALTER TABLE medias ADD COLUMN imdb_id TEXT;`,
			// Season/episode numbers for TMDB episode metadata.
			`ALTER TABLE medias ADD COLUMN season_number INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN episode_number INTEGER DEFAULT 0;`,
			// Streaming optimization columns.
			`ALTER TABLE medias ADD COLUMN file_size INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN tracks_json TEXT;`,
			`ALTER TABLE medias ADD COLUMN probed_at TIMESTAMP;`,
			`ALTER TABLE medias ADD COLUMN file_mod_time INTEGER DEFAULT 0;`,
			`ALTER TABLE medias ADD COLUMN gop_seconds REAL;`,

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
			// Ordering for the home "Continue Watching" row.
			`CREATE INDEX IF NOT EXISTS idx_progressions_updated_at ON progressions(updated_at DESC);`,

			`CREATE TABLE IF NOT EXISTS sessions (
				token TEXT PRIMARY KEY,
				user_id INTEGER NOT NULL,
				created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
				FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
			);`,

			// User-dismissed entries hidden from the home "Continue Watching" row only.
			`CREATE TABLE IF NOT EXISTS continue_watching_hidden (
				user_id INTEGER NOT NULL,
				entry_key TEXT NOT NULL,
				hidden_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
				PRIMARY KEY (user_id, entry_key),
				FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
			);`,

			// Pre-extracted external .vtt tracks discovered at scan time.
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
			// partial=1 means the .vtt only covers the beginning of the media: it is
			// written by the fast head pass so subtitles are usable within seconds on
			// a large remux, and replaced by the complete pass shortly after.
			`ALTER TABLE subtitles ADD COLUMN partial INTEGER NOT NULL DEFAULT 0;`,

			// App-wide settings (MediaHub, TMDB, library paths) — overrides env when set.
			`CREATE TABLE IF NOT EXISTS app_settings (
				key TEXT PRIMARY KEY,
				value TEXT NOT NULL,
				updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
			);`,

			// Named Player Studio layouts owned by a user (synced across devices).
			`CREATE TABLE IF NOT EXISTS user_player_layouts (
				id TEXT PRIMARY KEY,
				user_id INTEGER NOT NULL,
				name TEXT NOT NULL,
				config_json TEXT NOT NULL,
				use_modular BOOLEAN NOT NULL DEFAULT 0,
				updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
				FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
			);`,
			`CREATE INDEX IF NOT EXISTS idx_user_player_layouts_user_id
				ON user_player_layouts(user_id);`,

			// --- Administration rights (lot A) ---
			// The permission set is fixed by design (6 flags), so they live as columns
			// on users rather than in a join table: no join on the auth hot path.
			// is_owner is asymmetric and separate: the owner can demote any admin,
			// nobody can demote the owner. See docs/adr/0001-user-permissions.md.
			`ALTER TABLE users ADD COLUMN is_owner BOOLEAN NOT NULL DEFAULT 0;`,
			`ALTER TABLE users ADD COLUMN perm_manage_settings BOOLEAN NOT NULL DEFAULT 0;`,
			`ALTER TABLE users ADD COLUMN perm_manage_library BOOLEAN NOT NULL DEFAULT 0;`,
			`ALTER TABLE users ADD COLUMN perm_manage_users BOOLEAN NOT NULL DEFAULT 0;`,
			`ALTER TABLE users ADD COLUMN perm_delete_media BOOLEAN NOT NULL DEFAULT 0;`,
			`ALTER TABLE users ADD COLUMN perm_invite_users BOOLEAN NOT NULL DEFAULT 0;`,
			// request_media is the one permission a plain household account gets.
			`ALTER TABLE users ADD COLUMN perm_request_media BOOLEAN NOT NULL DEFAULT 1;`,
			// Invitation template: the permissions this user's links will grant. The
			// inviter never picks them — an admin sets them when granting invite_users,
			// which is what makes invite_users non-escalating.
			`ALTER TABLE users ADD COLUMN invite_grants TEXT NOT NULL DEFAULT '';`,

			// Single-use invitation links. grants is frozen at creation time; revoking
			// invite_users from the inviter cascades to their pending links.
			`CREATE TABLE IF NOT EXISTS invitations (
				token TEXT PRIMARY KEY,
				inviter_id INTEGER NOT NULL,
				grants TEXT NOT NULL DEFAULT '',
				status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'used', 'revoked')),
				created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
				expires_at TEXT NOT NULL,
				used_at TIMESTAMP,
				used_by_user_id INTEGER,
				FOREIGN KEY (inviter_id) REFERENCES users(id) ON DELETE CASCADE,
				FOREIGN KEY (used_by_user_id) REFERENCES users(id) ON DELETE SET NULL
			);`,
			`CREATE INDEX IF NOT EXISTS idx_invitations_inviter_id ON invitations(inviter_id);`,

			// One-shot backfill for installs that predate permissions: the oldest
			// account is the one that set the server up, so it becomes the owner.
			// Guarded by NOT EXISTS so a later ownership transfer is never undone.
			`UPDATE users SET
				is_owner = 1,
				perm_manage_settings = 1,
				perm_manage_library = 1,
				perm_manage_users = 1,
				perm_delete_media = 1,
				perm_invite_users = 1,
				perm_request_media = 1
			WHERE id = (SELECT MIN(id) FROM users)
			  AND NOT EXISTS (SELECT 1 FROM users WHERE is_owner = 1);`,
		},
	},
	{
		id:   2,
		name: "hot path indexes",
		// Each of these backs a query that used to force a full scan of medias.
		stmts: []string{
			// The indexer asks "is this file already indexed?" once per video file
			// found on disk. Without an index that is one full table scan per file,
			// i.e. quadratic in library size — by far the dominant cost of a scan.
			//
			// Deliberately NOT unique: an existing install may already hold duplicate
			// rows (that is what DedupeDuplicateShows/Movies clean up), and a UNIQUE
			// index would fail to build and take the server down at startup.
			`CREATE INDEX IF NOT EXISTS idx_medias_file_path ON medias(file_path);`,

			// tmdb_id lookups: attachLocalIDs (person/collection screens), canonical
			// show/movie resolution, and duplicate detection.
			`CREATE INDEX IF NOT EXISTS idx_medias_tmdb_id ON medias(tmdb_id);`,

			// GetMovies/GetShows filter on type and order by title. The composite
			// serves both halves, so the sort is read off the index instead of being
			// materialised on every request.
			`CREATE INDEX IF NOT EXISTS idx_medias_type_title ON medias(type, title);`,

			// Season/episode tree walks are always "children of X of type Y".
			`CREATE INDEX IF NOT EXISTS idx_medias_parent_type ON medias(parent_id, type);`,

			// The two composites above start with the same column as the original
			// single-column indexes, so those are now dead weight: they cost writes
			// on every scan insert and are never chosen.
			`DROP INDEX IF EXISTS idx_medias_parent_id;`,
			`DROP INDEX IF EXISTS idx_medias_type;`,

			// The library screens all join progressions the other way round:
			//   LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
			// medias drives that join, so the (user_id, media_id) primary key cannot
			// serve it — media_id is not its leading column — and SQLite falls back
			// to scanning progressions once per media row.
			`CREATE INDEX IF NOT EXISTS idx_progressions_media_id ON progressions(media_id, user_id);`,
		},
	},
	{
		id:   3,
		name: "session idle deadline",
		stmts: []string{
			// Sessions expire on inactivity, not on age. Bumping created_at would lie
			// about when the session was opened, so the sliding deadline gets its own
			// column; NULL means "never seen since login", and the expiry check falls
			// back to created_at for rows that predate this.
			`ALTER TABLE sessions ADD COLUMN last_seen_at TIMESTAMP;`,
			// Session lookups are by token (the primary key), but expiry sweeps read
			// by age and admin resets delete by user.
			`CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);`,
		},
	},
	{
		id:   4,
		name: "device pairing",
		stmts: []string{
			// TV pairing. A television has no keyboard, so it never types a
			// password: it opens a pairing, shows the short code as a QR, and
			// polls until a phone that is already signed in approves it. The
			// row holds the session token created at approval, which the TV
			// then collects exactly once.
			`CREATE TABLE IF NOT EXISTS device_pairings (
				device_code TEXT PRIMARY KEY,
				user_code TEXT NOT NULL UNIQUE,
				device_name TEXT NOT NULL DEFAULT '',
				created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
				expires_at TIMESTAMP NOT NULL,
				approved_user_id INTEGER,
				session_token TEXT,
				FOREIGN KEY (approved_user_id) REFERENCES users(id) ON DELETE CASCADE
			);`,
			// The phone approves by short code, and the reaper sweeps by expiry.
			`CREATE INDEX IF NOT EXISTS idx_device_pairings_user_code ON device_pairings(user_code);`,
			`CREATE INDEX IF NOT EXISTS idx_device_pairings_expires_at ON device_pairings(expires_at);`,
		},
	},
}

// applyMigrations brings the database up to the latest schema version.
func applyMigrations(db *sql.DB) error {
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS schema_migrations (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		);`); err != nil {
		return fmt.Errorf("failed to create schema_migrations: %w", err)
	}

	applied, err := appliedMigrations(db)
	if err != nil {
		return err
	}

	ran := 0
	for _, m := range migrations {
		if applied[m.id] {
			continue
		}
		if err := runMigration(db, m); err != nil {
			return err
		}
		log.Printf("Database: applied migration %04d %s", m.id, m.name)
		ran++
	}

	if ran == 0 {
		log.Printf("Database: schema up to date (%d migration(s) applied previously).", len(applied))
	}
	return nil
}

func appliedMigrations(db *sql.DB) (map[int]bool, error) {
	rows, err := db.Query(`SELECT id FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("failed to read schema_migrations: %w", err)
	}
	defer rows.Close()

	applied := map[int]bool{}
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		applied[id] = true
	}
	return applied, rows.Err()
}

// runMigration applies one migration atomically: either every statement lands
// and the version is recorded, or the database is left exactly as it was.
func runMigration(db *sql.DB, m migration) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("migration %04d: begin: %w", m.id, err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op once committed

	for _, stmt := range m.stmts {
		if _, err := tx.Exec(stmt); err != nil {
			if isAlreadyAppliedColumn(stmt, err) {
				continue
			}
			return fmt.Errorf("migration %04d (%s), statement [%s]: %w",
				m.id, m.name, firstLine(stmt), err)
		}
	}

	if _, err := tx.Exec(
		`INSERT INTO schema_migrations (id, name) VALUES (?, ?)`, m.id, m.name,
	); err != nil {
		return fmt.Errorf("migration %04d: record: %w", m.id, err)
	}
	return tx.Commit()
}

// isAlreadyAppliedColumn reports whether the error is SQLite refusing an
// ADD COLUMN that is already there.
//
// This is the one error worth tolerating, and only on this one statement shape:
// a column that already exists means the migration's effect is present, which
// is exactly what it wanted. The old code applied the same string match to
// every statement, so an unrelated failure that happened to mention a duplicate
// column passed silently.
func isAlreadyAppliedColumn(stmt string, err error) bool {
	upper := strings.ToUpper(stmt)
	if !strings.HasPrefix(strings.TrimSpace(upper), "ALTER TABLE") ||
		!strings.Contains(upper, "ADD COLUMN") {
		return false
	}
	return strings.Contains(err.Error(), "duplicate column name")
}

func firstLine(stmt string) string {
	if i := strings.IndexByte(stmt, '\n'); i >= 0 {
		return strings.TrimSpace(stmt[:i]) + " …"
	}
	return strings.TrimSpace(stmt)
}
