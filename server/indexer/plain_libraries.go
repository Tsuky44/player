package indexer

import (
	"path/filepath"
	"strings"

	"project-player/server/libraries"
)

// Les bibliothèques « autre » (libraries.KindOther, ADR-0058) : des vidéos
// présentées sous le nom de leur fichier, que le serveur ne cherche jamais à
// reconnaître. Un film de vacances nommé « Noël 2019 » n'est pas le film
// « Noël » de TMDB, et il n'a pas sa place dans la file des médias mal
// identifiés.
//
// Ces vidéos sont rangées comme des films sans identité (tmdb_id à 0) : tout
// ce qui, ailleurs, rattrape un film sans identité doit donc passer par ici
// pour les laisser tranquilles.

// plainTitle is the name of a video of a plain library: its file name, as its
// owner wrote it.
func plainTitle(path string) string {
	name := filepath.Base(path)
	return strings.TrimSuffix(name, filepath.Ext(name))
}

// InPlainLibrary reports whether a stored file path belongs to a library whose
// content is not identified.
func InPlainLibrary(filePath string) bool {
	if filePath == "" {
		return false
	}
	for _, lib := range libraries.OfKind(libraries.Current(), libraries.KindOther) {
		lower, upper := pathPrefixRange(lib.Path)
		if filePath >= lower && filePath < upper {
			return true
		}
	}
	return false
}

// OutsidePlainLibraries returns a SQL condition, with its arguments, keeping
// only the rows whose path column is outside every plain library. It starts
// with " AND" and is empty when there is none; rows without a path (shows,
// seasons) are kept.
func OutsidePlainLibraries(column string) (string, []interface{}) {
	var condition strings.Builder
	var args []interface{}
	for _, lib := range libraries.OfKind(libraries.Current(), libraries.KindOther) {
		lower, upper := pathPrefixRange(lib.Path)
		condition.WriteString(" AND NOT (COALESCE(" + column + ", '') >= ? AND COALESCE(" + column + ", '') < ?)")
		args = append(args, lower, upper)
	}
	return condition.String(), args
}
