package database

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
)

// Une migration ne se défait pas : la base d'avant doit rester lisible à côté,
// avec ce qu'elle contenait.
func TestBackupBeforeMigratingKeepsAReadableCopy(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "player.db")
	db, err := InitDB(dbPath)
	if err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`INSERT INTO medias (type, title) VALUES ('movie', 'Avant la migration')`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	target, err := backupBeforeMigrating(db, dbPath, 21)
	if err != nil {
		t.Fatalf("backup: %v", err)
	}
	if target == "" {
		t.Fatal("no backup was written for a database on disk")
	}

	copyDB, err := sql.Open("sqlite", target)
	if err != nil {
		t.Fatalf("open backup: %v", err)
	}
	defer copyDB.Close()
	var title string
	if err := copyDB.QueryRow(`SELECT title FROM medias`).Scan(&title); err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if title != "Avant la migration" {
		t.Errorf("backup holds %q", title)
	}
}

// Une base neuve n'a rien à perdre : pas de copie au premier démarrage.
func TestAFreshDatabaseIsNotBackedUp(t *testing.T) {
	dir := t.TempDir()
	db, err := InitDB(filepath.Join(dir, "player.db"))
	if err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	if left, _ := filepath.Glob(filepath.Join(dir, "*"+migrationBackupSuffix)); len(left) != 0 {
		t.Errorf("a first start wrote backups: %v", left)
	}
}

// Une base déjà en service qui reçoit une migration est copiée d'abord.
func TestAPendingMigrationOnALiveDatabaseTriggersABackup(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "player.db")
	db, err := InitDB(dbPath)
	if err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	// Une migration de plus que ce que la base a joué, sans effet sur le schéma.
	saved := migrations
	migrations = append(append([]migration{}, saved...), migration{
		id: saved[len(saved)-1].id + 1, name: "test", stmts: []string{`SELECT 1;`},
	})
	t.Cleanup(func() { migrations = saved })

	if err := applyMigrations(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if left, _ := filepath.Glob(dbPath + ".pre-*" + migrationBackupSuffix); len(left) != 1 {
		t.Errorf("expected one backup before the pending migration, got %v", left)
	}
}

func TestOnlyTheNewestBackupsAreKept(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "player.db")
	names := []string{
		dbPath + ".pre-0018-20260101T000000.bak",
		dbPath + ".pre-0019-20260301T000000.bak",
		dbPath + ".pre-0020-20260201T000000.bak",
		dbPath + ".pre-0021-20260401T000000.bak",
	}
	for _, name := range names {
		if err := os.WriteFile(name, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	pruneMigrationBackups(dbPath, 2)

	for i, name := range names {
		_, err := os.Stat(name)
		kept := err == nil
		// Les deux plus récentes par date : mars et avril.
		if want := i == 1 || i == 3; kept != want {
			t.Errorf("%s kept=%v, want %v", filepath.Base(name), kept, want)
		}
	}
}
