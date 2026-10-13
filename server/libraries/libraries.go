// Package libraries tient la liste des bibliothèques du serveur.
//
// Une bibliothèque, c'est un dossier de médias, le nom que l'administrateur lui
// donne et la façon de le lire (des films, ou des séries rangées par épisodes).
// Le serveur n'en impose aucune : il y en a autant qu'on en déclare, et rien
// dans le code ne suppose « Films » ni « Séries ». Voir ADR-0058.
//
// L'appartenance d'un média à une bibliothèque n'est pas stockée : c'est son
// chemin. Un fichier appartient à la bibliothèque dont le dossier le contient,
// ce qui reste vrai quand on renomme la bibliothèque ou qu'on en déplace le
// dossier, sans rien à resynchroniser.
package libraries

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"project-player/server/database"
)

// Kind dit comment le contenu d'un dossier se lit.
type Kind string

const (
	// KindMovies : un fichier vidéo est une œuvre.
	KindMovies Kind = "movies"
	// KindShows : les fichiers sont des épisodes, rangés par série et saison.
	KindShows Kind = "shows"
	// KindOther : ni l'un ni l'autre — vidéos de famille, concerts, cours.
	// Chaque fichier est présenté sous son propre nom, et le serveur ne
	// cherche pas à le reconnaître dans un catalogue.
	KindOther Kind = "other"
)

// Valid reports whether k is a kind the indexer knows how to read.
func (k Kind) Valid() bool { return k == KindMovies || k == KindShows || k == KindOther }

// MaxNameLength borne le nom d'une bibliothèque, en caractères : il s'affiche
// dans un onglet.
const MaxNameLength = 40

// Library est une bibliothèque telle que l'API la renvoie. Path n'est rempli
// que pour qui administre le serveur : c'est l'arborescence de son disque.
type Library struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Kind Kind   `json:"kind"`
	Path string `json:"path,omitempty"`
}

var (
	ErrNotFound     = errors.New("libraries: not found")
	ErrInvalidName  = errors.New("libraries: invalid name")
	ErrInvalidKind  = errors.New("libraries: invalid kind")
	ErrInvalidPath  = errors.New("libraries: invalid path")
	ErrPathNotFound = errors.New("libraries: path is not a folder on the server")
	// ErrPathTaken : un dossier, une bibliothèque.
	ErrPathTaken = errors.New("libraries: path already belongs to a library")
)

// List returns every library, oldest first.
func List() ([]Library, error) {
	rows, err := database.DB.Query(`SELECT id, name, kind, path FROM libraries ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("libraries: list: %w", err)
	}
	defer rows.Close()

	libs := []Library{}
	for rows.Next() {
		var lib Library
		if err := rows.Scan(&lib.ID, &lib.Name, &lib.Kind, &lib.Path); err != nil {
			return nil, fmt.Errorf("libraries: scan: %w", err)
		}
		libs = append(libs, lib)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("libraries: list: %w", err)
	}
	return libs, nil
}

var (
	lastGoodMu sync.Mutex
	lastGood   []Library
)

// Current is List for the callers that run on a timer and cannot fail: the
// scans and the library monitor. A read that fails returns the last list that
// was read rather than "no library", which the monitor would take for every
// library having been removed.
func Current() []Library {
	libs, err := List()
	lastGoodMu.Lock()
	defer lastGoodMu.Unlock()
	if err != nil {
		log.Printf("%v — keeping the previous list", err)
		return append([]Library(nil), lastGood...)
	}
	lastGood = append([]Library(nil), libs...)
	return libs
}

// Get returns one library, or ErrNotFound.
func Get(id int) (Library, error) {
	var lib Library
	err := database.DB.QueryRow(`SELECT id, name, kind, path FROM libraries WHERE id = ?`, id).
		Scan(&lib.ID, &lib.Name, &lib.Kind, &lib.Path)
	if errors.Is(err, sql.ErrNoRows) {
		return Library{}, ErrNotFound
	}
	if err != nil {
		return Library{}, fmt.Errorf("libraries: get %d: %w", id, err)
	}
	return lib, nil
}

// Create declares a new library over an existing folder of the server.
func Create(name string, kind Kind, path string) (Library, error) {
	name, err := cleanName(name)
	if err != nil {
		return Library{}, err
	}
	if !kind.Valid() {
		return Library{}, ErrInvalidKind
	}
	path, err = cleanFolder(path)
	if err != nil {
		return Library{}, err
	}

	res, err := database.DB.Exec(`INSERT INTO libraries (name, kind, path) VALUES (?, ?, ?)`, name, kind, path)
	if err != nil {
		if isUniqueViolation(err) {
			return Library{}, ErrPathTaken
		}
		return Library{}, fmt.Errorf("libraries: create: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Library{}, fmt.Errorf("libraries: create: %w", err)
	}
	return Library{ID: int(id), Name: name, Kind: kind, Path: path}, nil
}

// Update renames a library and/or points it at another folder. It returns the
// library as it was, so the caller can tell whether the folder moved.
//
// Le type ne se change pas : les fiches d'un dossier lu comme des films ne
// deviennent pas des épisodes. On supprime la bibliothèque et on la recrée.
func Update(id int, name, path string) (previous, updated Library, err error) {
	previous, err = Get(id)
	if err != nil {
		return Library{}, Library{}, err
	}
	name, err = cleanName(name)
	if err != nil {
		return Library{}, Library{}, err
	}
	// Le dossier n'est revérifié que s'il change : renommer une bibliothèque
	// dont le disque est débranché doit rester possible.
	if filepath.Clean(strings.TrimSpace(path)) != previous.Path {
		if path, err = cleanFolder(path); err != nil {
			return Library{}, Library{}, err
		}
	} else {
		path = previous.Path
	}

	if _, err := database.DB.Exec(`UPDATE libraries SET name = ?, path = ? WHERE id = ?`, name, path, id); err != nil {
		if isUniqueViolation(err) {
			return Library{}, Library{}, ErrPathTaken
		}
		return Library{}, Library{}, fmt.Errorf("libraries: update %d: %w", id, err)
	}
	updated = Library{ID: id, Name: name, Kind: previous.Kind, Path: path}
	return previous, updated, nil
}

// Delete removes a library and returns it. Its indexed medias are the
// indexer's to forget: see indexer.ForgetMediaUnder.
func Delete(id int) (Library, error) {
	lib, err := Get(id)
	if err != nil {
		return Library{}, err
	}
	if _, err := database.DB.Exec(`DELETE FROM libraries WHERE id = ?`, id); err != nil {
		return Library{}, fmt.Errorf("libraries: delete %d: %w", id, err)
	}
	return lib, nil
}

// OfKind keeps the libraries of one kind.
func OfKind(libs []Library, kind Kind) []Library {
	var kept []Library
	for _, lib := range libs {
		if lib.Kind == kind {
			kept = append(kept, lib)
		}
	}
	return kept
}

// Paths lists the folders of libs.
func Paths(libs []Library) []string {
	paths := make([]string, 0, len(libs))
	for _, lib := range libs {
		paths = append(paths, lib.Path)
	}
	return paths
}

// PathRange bounds the stored paths beneath dir as a half-open range,
// [dir + "/", dir + "0"): '0' is the character after '/', so the range holds
// exactly the paths that continue with a slash. Unlike LIKE, a range is served
// by idx_medias_file_path, and it has no wildcard to escape in a folder name.
func PathRange(dir string) (lower, upper string) {
	base := strings.TrimSuffix(filepath.ToSlash(filepath.Clean(dir)), "/")
	return base + "/", base + "0"
}

func cleanName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > MaxNameLength {
		return "", ErrInvalidName
	}
	return name, nil
}

// cleanFolder normalise un chemin saisi et vérifie que c'est un dossier que le
// serveur voit : une faute de frappe se dit à la saisie, pas au scan suivant
// par une bibliothèque vide.
func cleanFolder(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return "", ErrInvalidPath
	}
	path = filepath.Clean(path)
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return "", ErrPathNotFound
	}
	return path, nil
}

func isUniqueViolation(err error) bool {
	return strings.Contains(err.Error(), "UNIQUE constraint failed")
}
