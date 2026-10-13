package database

import (
	"path/filepath"
	"testing"
)

type seededLibrary struct{ name, kind, path string }

func seededLibraries(t *testing.T) []seededLibrary {
	t.Helper()
	rows, err := DB.Query(`SELECT name, kind, path FROM libraries ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var libs []seededLibrary
	for rows.Next() {
		var lib seededLibrary
		if err := rows.Scan(&lib.name, &lib.kind, &lib.path); err != nil {
			t.Fatal(err)
		}
		libs = append(libs, lib)
	}
	return libs
}

// reseed rejoue la reprise des anciens dossiers sur la base ouverte, comme la
// migration 22 la joue une fois sur une installation mise à jour.
func reseed(t *testing.T) {
	t.Helper()
	tx, err := DB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback() //nolint:errcheck // sans effet une fois validée
	if _, err := tx.Exec(`DELETE FROM libraries`); err != nil {
		t.Fatal(err)
	}
	if err := seedLibrariesFromLegacyDirs(tx); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func openSeedDB(t *testing.T) {
	t.Helper()
	if _, err := InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { DB.Close() })
}

// L'image pose MOVIES_DIR et SERIES_DIR pour tout le monde : un serveur neuf ne
// doit pas en tirer deux bibliothèques « Films » et « Séries » que personne n'a
// demandées. C'est son administrateur qui les déclare (ADR-0058).
func TestAFreshServerStartsWithoutAnyLibrary(t *testing.T) {
	t.Setenv("MOVIES_DIR", t.TempDir())
	t.Setenv("SERIES_DIR", t.TempDir())
	openSeedDB(t)

	if libs := seededLibraries(t); len(libs) != 0 {
		t.Fatalf("a fresh server was given libraries: %+v", libs)
	}
}

func TestAnInstallWithACatalogKeepsItsTwoFoldersAsLibraries(t *testing.T) {
	movies, series := t.TempDir(), t.TempDir()
	t.Setenv("MOVIES_DIR", movies)
	t.Setenv("SERIES_DIR", series)
	openSeedDB(t)
	if _, err := DB.Exec(`INSERT INTO medias (type, title, file_path) VALUES ('movie', 'Dune', ?)`,
		filepath.ToSlash(filepath.Join(movies, "Dune.mkv"))); err != nil {
		t.Fatal(err)
	}

	reseed(t)

	libs := seededLibraries(t)
	want := []seededLibrary{
		{"Films", "movies", filepath.Clean(movies)},
		{"Séries", "shows", filepath.Clean(series)},
	}
	if len(libs) != len(want) || libs[0] != want[0] || libs[1] != want[1] {
		t.Fatalf("libraries = %+v, want %+v", libs, want)
	}
}

// Un dossier enregistré dans les réglages est un choix de l'administrateur : il
// est repris même si rien n'y a encore été indexé, et il passe avant
// l'environnement.
func TestAFolderChosenInTheSettingsIsAlwaysKept(t *testing.T) {
	t.Setenv("MOVIES_DIR", t.TempDir())
	t.Setenv("SERIES_DIR", "")
	openSeedDB(t)
	chosen := t.TempDir()
	if _, err := DB.Exec(`INSERT INTO app_settings (key, value) VALUES ('movies_dir', ?)`, chosen); err != nil {
		t.Fatal(err)
	}

	reseed(t)

	libs := seededLibraries(t)
	if len(libs) != 1 || libs[0].path != filepath.Clean(chosen) || libs[0].kind != "movies" {
		t.Fatalf("libraries = %+v, want the folder of the settings only", libs)
	}
	var left int
	if err := DB.QueryRow(`SELECT COUNT(*) FROM app_settings WHERE key IN ('movies_dir', 'series_dir')`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatal("the legacy settings outlived the libraries that replace them")
	}
}
