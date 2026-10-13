package libraries

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
)

func setupDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
}

func TestAServerHoldsAsManyLibrariesAsDeclared(t *testing.T) {
	setupDB(t)
	names := []string{"Films", "Animés", "Documentaires", "Concerts filmés"}
	for i, name := range names {
		kind := KindMovies
		if i%2 == 1 {
			kind = KindShows
		}
		if _, err := Create(name, kind, t.TempDir()); err != nil {
			t.Fatalf("create %q: %v", name, err)
		}
	}

	libs, err := List()
	if err != nil {
		t.Fatal(err)
	}
	if len(libs) != len(names) {
		t.Fatalf("libraries = %d, want %d", len(libs), len(names))
	}
	for i, lib := range libs {
		if lib.Name != names[i] {
			t.Fatalf("library %d is %q, want %q — they are listed in creation order", i, lib.Name, names[i])
		}
	}
	if shows := OfKind(libs, KindShows); len(shows) != 2 {
		t.Fatalf("shows libraries = %d, want 2", len(shows))
	}
}

func TestAFolderBelongsToOneLibraryOnly(t *testing.T) {
	setupDB(t)
	dir := t.TempDir()
	if _, err := Create("Films", KindMovies, dir); err != nil {
		t.Fatal(err)
	}
	// Le même dossier écrit autrement reste le même dossier.
	if _, err := Create("Encore", KindShows, dir+string(filepath.Separator)); !errors.Is(err, ErrPathTaken) {
		t.Fatalf("second library on the same folder: err = %v, want ErrPathTaken", err)
	}
}

func TestCreateRefusesWhatCannotBeIndexed(t *testing.T) {
	setupDB(t)
	dir := t.TempDir()
	cases := []struct {
		label, name string
		kind        Kind
		path        string
		want        error
	}{
		{"no name", "  ", KindMovies, dir, ErrInvalidName},
		{"name too long for a tab", strings.Repeat("é", MaxNameLength+1), KindMovies, dir, ErrInvalidName},
		{"unknown kind", "Musique", Kind("music"), dir, ErrInvalidKind},
		{"no folder", "Films", KindMovies, "", ErrInvalidPath},
		{"relative folder", "Films", KindMovies, "media/films", ErrInvalidPath},
		{"folder the server does not see", "Films", KindMovies, filepath.Join(dir, "absent"), ErrPathNotFound},
	}
	for _, c := range cases {
		if _, err := Create(c.name, c.kind, c.path); !errors.Is(err, c.want) {
			t.Errorf("%s: err = %v, want %v", c.label, err, c.want)
		}
	}
	// Un nom à la limite, en caractères et non en octets, passe.
	if _, err := Create(strings.Repeat("é", MaxNameLength), KindMovies, dir); err != nil {
		t.Errorf("a %d-character name was refused: %v", MaxNameLength, err)
	}
}

func TestRenamingALibraryDoesNotNeedItsFolderOnline(t *testing.T) {
	setupDB(t)
	lib, err := Create("Films", KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// Le disque est débranché : le dossier n'existe plus pour le serveur.
	gone := filepath.Join(t.TempDir(), "unmounted")
	if _, err := database.DB.Exec(`UPDATE libraries SET path = ? WHERE id = ?`, gone, lib.ID); err != nil {
		t.Fatal(err)
	}

	previous, updated, err := Update(lib.ID, "Cinéma", gone)
	if err != nil {
		t.Fatalf("rename with the folder offline: %v", err)
	}
	if updated.Name != "Cinéma" || updated.Path != previous.Path || updated.Kind != KindMovies {
		t.Fatalf("updated = %+v", updated)
	}
}

func TestMovingALibraryChecksTheNewFolder(t *testing.T) {
	setupDB(t)
	lib, err := Create("Films", KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	other, err := Create("Séries", KindShows, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	if _, _, err := Update(lib.ID, "Films", filepath.Join(lib.Path, "absent")); !errors.Is(err, ErrPathNotFound) {
		t.Fatalf("move to a missing folder: err = %v, want ErrPathNotFound", err)
	}
	if _, _, err := Update(lib.ID, "Films", other.Path); !errors.Is(err, ErrPathTaken) {
		t.Fatalf("move onto another library: err = %v, want ErrPathTaken", err)
	}
	moved := t.TempDir()
	previous, updated, err := Update(lib.ID, "Films", moved)
	if err != nil {
		t.Fatal(err)
	}
	if previous.Path != lib.Path || updated.Path != filepath.Clean(moved) {
		t.Fatalf("previous = %q, updated = %q", previous.Path, updated.Path)
	}
}

func TestDeleteAndUnknownLibrary(t *testing.T) {
	setupDB(t)
	lib, err := Create("Films", KindMovies, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	deleted, err := Delete(lib.ID)
	if err != nil || deleted.Path != lib.Path {
		t.Fatalf("delete = %+v, %v", deleted, err)
	}
	if _, err := Get(lib.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get after delete: err = %v, want ErrNotFound", err)
	}
	if _, err := Delete(lib.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: err = %v, want ErrNotFound", err)
	}
	if len(Current()) != 0 {
		t.Fatal("a deleted library is still listed")
	}
}

func TestPathRangeHoldsOnlyWhatTheFolderContains(t *testing.T) {
	lower, upper := PathRange("/media/Films/")
	within := func(path string) bool { return path >= lower && path < upper }
	if !within("/media/Films/Dune (2021)/Dune.mkv") {
		t.Fatal("a file of the folder is outside its range")
	}
	// « Films 4K » commence comme « Films » sans en faire partie.
	if within("/media/Films 4K/Dune.mkv") || within("/media/Films") {
		t.Fatal("the range leaks into a sibling folder")
	}
}
