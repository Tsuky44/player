package handlers

import (
	"fmt"

	"project-player/server/indexer"
	"project-player/server/libraries"
	"project-player/server/models"
)

// Les rangées « derniers ajouts » de l'accueil, une par bibliothèque, sous le
// nom que son administrateur lui a donné (ADR-0058). Elles remplacent, pour les
// apps qui les lisent, les deux rangées « films récents » et « séries
// récentes » dont le titre était écrit dans l'app.

// recentMovieCardKeysWithin is recentMovieCardKeys for the files of one folder.
const recentMovieCardKeysWithin = `
		SELECT COALESCE(NULLIF(tmdb_id, 0), -id)
		FROM medias
		WHERE type = 'movie' AND file_path >= ? AND file_path < ?
		GROUP BY COALESCE(NULLIF(tmdb_id, 0), -id)
		ORDER BY MAX(created_at) DESC, MAX(id) DESC
		LIMIT ?`

// recentShowKeysWithin is recentShowKeys for the series holding an episode
// file in one folder, ordered by the newest of those files.
const recentShowKeysWithin = `
		SELECT s.id AS show_id, MAX(ep.created_at) AS last_added
		FROM medias s
		JOIN medias season ON season.type = 'season' AND season.parent_id = s.id
		JOIN medias ep ON ep.type = 'episode' AND ep.parent_id = season.id
		WHERE s.type = 'show' AND ep.file_path >= ? AND ep.file_path < ?
		GROUP BY s.id
		ORDER BY last_added DESC, s.id DESC
		LIMIT ?`

// buildHomeLibraryRows returns one row per library that holds something, in
// the order of the libraries.
func buildHomeLibraryRows() ([]models.HomeLibraryRow, error) {
	libs, err := libraries.List()
	if err != nil {
		return nil, err
	}
	rows := []models.HomeLibraryRow{}
	for _, lib := range libs {
		items, err := recentLibraryItems(lib)
		if err != nil {
			return nil, fmt.Errorf("home row of library %d: %w", lib.ID, err)
		}
		if len(items) == 0 {
			continue
		}
		rows = append(rows, models.HomeLibraryRow{
			ID: lib.ID, Name: lib.Name, Kind: string(lib.Kind), Items: items,
		})
	}
	return rows, nil
}

func recentLibraryItems(lib libraries.Library) ([]models.Media, error) {
	lower, upper := libraries.PathRange(lib.Path)

	if lib.Kind == libraries.KindShows {
		shows, err := queryMediaList("Home library shows", `
			SELECT `+mediaColumns+`
			FROM medias m
			JOIN (`+recentShowKeysWithin+`) recent ON recent.show_id = m.id
			ORDER BY recent.last_added DESC, m.id DESC`, lower, upper, homeRecentShows*2)
		if err != nil {
			return nil, err
		}
		// Comme pour la rangée de tout le serveur : les doublons d'une même
		// série se replient après le tri, d'où la marge demandée.
		shows = indexer.DedupeShowMediaListForDisplay(shows)
		if len(shows) > homeRecentShows {
			shows = shows[:homeRecentShows]
		}
		return shows, nil
	}

	movies, err := queryMediaList("Home library movies", `
		SELECT `+mediaColumns+`
		FROM medias m
		WHERE m.type = 'movie'
		  AND m.file_path >= ? AND m.file_path < ?
		  AND `+movieCardKey("m")+` IN (`+recentMovieCardKeysWithin+`)
		ORDER BY m.created_at DESC, m.id DESC`, lower, upper, lower, upper, homeRecentMovies)
	if err != nil {
		return nil, err
	}
	movies, err = groupMovieCards(movies)
	if err != nil {
		return nil, err
	}
	if len(movies) > homeRecentMovies {
		movies = movies[:homeRecentMovies]
	}
	return movies, nil
}
