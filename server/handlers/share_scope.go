package handlers

import (
	"fmt"
	"sort"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"
	"project-player/server/sharelinks"
)

// Ce qu'un lien de partage couvre (ADR-0037 §8) : un film ou un épisode, ou
// bien une saison ou une série entière. Le lien d'une saison ou d'une série ne
// garde que l'id de celle-ci : ses épisodes sont relus à chaque ouverture, pour
// qu'un épisode arrivé après la création du lien en fasse partie, et qu'un
// épisode sans fichier n'y figure pas.

// sharedEpisodesFrom désigne les épisodes lisibles de la saison ou de la
// série ?, passée deux fois. Un id de série ne peut pas égaler celui d'une
// saison, ni l'inverse : une seule des deux branches répond.
const sharedEpisodesFrom = `
		FROM medias e
		JOIN medias season ON season.id = e.parent_id AND season.type = 'season'
		WHERE e.type = 'episode' AND COALESCE(e.file_path, '') != ''
		  AND (season.id = ? OR season.parent_id = ?)`

func isShareCollection(mediaType string) bool {
	return mediaType == string(models.TypeShow) || mediaType == string(models.TypeSeason)
}

// shareScopeID renvoie la fiche dont un lien posé sur mediaID ouvre les
// épisodes. Une série indexée en double a plusieurs fiches, et ses saisons
// pendent à une seule, la canonique : c'est celle que /api/shows/:id/seasons
// montre. Un lien posé sur l'autre fiche n'ouvrait que ce qui y traînait
// encore — une saison, parfois aucune — au lieu de la série affichée.
func shareScopeID(mediaID int) int {
	return indexer.ResolveCanonicalShowID(mediaID)
}

// shareableMediaType dit si mediaID peut porter un lien, de quel type il est,
// et sur quelle fiche le poser (voir shareScopeID) : un film ou un épisode qui
// a un fichier, une saison ou une série qui a au moins un épisode lisible.
func shareableMediaType(mediaID int) (scopeID int, mediaType string, shareable bool) {
	if err := database.DB.QueryRow("SELECT type FROM medias WHERE id = ?", mediaID).Scan(&mediaType); err != nil {
		return mediaID, "", false
	}
	if !isShareCollection(mediaType) {
		return mediaID, mediaType, isPlayableMedia(mediaID)
	}
	scopeID = shareScopeID(mediaID)
	var episodes int
	if err := database.DB.QueryRow("SELECT COUNT(*)"+sharedEpisodesFrom, scopeID, scopeID).Scan(&episodes); err != nil {
		return scopeID, "", false
	}
	return scopeID, mediaType, episodes > 0
}

// sharedPlayTarget renvoie le média qu'une ouverture du lien doit lire :
// celui du lien, ou l'épisode demandé s'il appartient à la saison ou à la
// série partagée. Le code d'un lien n'ouvre rien d'autre.
func sharedPlayTarget(share sharelinks.Share, requested int) (int, bool) {
	if requested <= 0 || requested == share.MediaID {
		return share.MediaID, isPlayableMedia(share.MediaID)
	}
	// Un lien créé avant shareScopeID peut encore désigner une fiche en double.
	scopeID := shareScopeID(share.MediaID)
	var id int
	err := database.DB.QueryRow("SELECT e.id"+sharedEpisodesFrom+" AND e.id = ?",
		scopeID, scopeID, requested).Scan(&id)
	return id, err == nil
}

// loadSharedEpisodes liste les épisodes lisibles de la saison ou de la série
// scopeID, dans l'ordre de diffusion.
//
// Le numéro de saison vient de l'épisode, sinon de sa saison, sinon du titre
// de celle-ci (« Saison 3 ») : une saison indexée depuis un dossier n'a souvent
// pas de numéro, et ses épisodes se mêlaient alors à ceux des autres saisons
// dans une seule liste sans titre.
func loadSharedEpisodes(scopeID int) ([]models.SharedEpisode, error) {
	scopeID = shareScopeID(scopeID)
	rows, err := database.DB.Query(`
		SELECT e.id, COALESCE(e.season_number, 0), COALESCE(season.season_number, 0),
		       season.title, COALESCE(e.episode_number, 0), e.title, COALESCE(e.duration, 0)`+sharedEpisodesFrom,
		scopeID, scopeID)
	if err != nil {
		return nil, fmt.Errorf("list shared episodes of %d: %w", scopeID, err)
	}
	defer rows.Close()
	var out []models.SharedEpisode
	for rows.Next() {
		var episode models.SharedEpisode
		var seasonNumber int
		var seasonTitle string
		if err := rows.Scan(&episode.ID, &episode.SeasonNumber, &seasonNumber, &seasonTitle,
			&episode.EpisodeNumber, &episode.Title, &episode.Duration); err != nil {
			return nil, fmt.Errorf("scan shared episode: %w", err)
		}
		if episode.SeasonNumber <= 0 {
			episode.SeasonNumber = seasonNumber
		}
		if episode.SeasonNumber <= 0 {
			episode.SeasonNumber = seasonNumberFromTitle(seasonTitle)
		}
		out = append(out, episode)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list shared episodes of %d: %w", scopeID, err)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.SeasonNumber != b.SeasonNumber {
			return a.SeasonNumber < b.SeasonNumber
		}
		if a.EpisodeNumber != b.EpisodeNumber {
			return a.EpisodeNumber < b.EpisodeNumber
		}
		return a.ID < b.ID
	})
	return out, nil
}

// shareDisplay nomme le média d'un lien pour quelqu'un qui ne voit que lui :
// la série d'abord, puis ce que le lien en ouvre.
type shareDisplay struct {
	mediaType string
	title     string
	subtitle  string
	posterURL string
}

// seasonShow est ce qu'une saison emprunte à sa série pour se nommer.
type seasonShow struct {
	number    int
	title     string
	posterURL string
}

func loadShareDisplay(mediaID int) (shareDisplay, error) {
	displays, err := loadShareDisplays([]int{mediaID})
	if err != nil {
		return shareDisplay{}, err
	}
	display, ok := displays[mediaID]
	if !ok {
		return shareDisplay{}, fmt.Errorf("media %d not found", mediaID)
	}
	return display, nil
}

// loadShareDisplays nomme plusieurs médias en deux requêtes : les médias, puis
// la série des saisons parmi eux (le snapshot ne remonte à la série que pour
// un épisode).
func loadShareDisplays(mediaIDs []int) (map[int]shareDisplay, error) {
	snaps, err := loadMediaSnapshots(mediaIDs)
	if err != nil {
		return nil, err
	}
	var seasonIDs []int
	for id, snap := range snaps {
		if snap.mediaType == string(models.TypeSeason) {
			seasonIDs = append(seasonIDs, id)
		}
	}
	shows, err := loadSeasonShows(seasonIDs)
	if err != nil {
		return nil, err
	}
	out := make(map[int]shareDisplay, len(snaps))
	for id, snap := range snaps {
		out[id] = newShareDisplay(snap, shows[id])
	}
	return out, nil
}

func newShareDisplay(snap mediaSnapshot, show seasonShow) shareDisplay {
	display := shareDisplay{mediaType: snap.mediaType, title: snap.title, posterURL: snap.posterURL}
	switch snap.mediaType {
	case string(models.TypeShow):
		display.subtitle = "Série entière"
	case string(models.TypeSeason):
		// Le titre d'une saison (« Saison 1 », « Specials ») ne dit pas de
		// quelle série elle est.
		display.subtitle = snap.title
		if show.number > 0 {
			display.subtitle = fmt.Sprintf("Saison %d", show.number)
		}
		if show.title != "" {
			display.title = show.title
		}
		if display.posterURL == "" {
			display.posterURL = show.posterURL
		}
	case string(models.TypeEpisode):
		if snap.showTitle == "" {
			break
		}
		display.title, display.subtitle = snap.showTitle, snap.subtitle
		if snap.title != "" && snap.subtitle != "" {
			display.subtitle = snap.subtitle + " · " + snap.title
		} else if snap.title != "" {
			display.subtitle = snap.title
		}
	}
	return display
}

func loadSeasonShows(seasonIDs []int) (map[int]seasonShow, error) {
	out := make(map[int]seasonShow, len(seasonIDs))
	if len(seasonIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(seasonIDs))
	for i, id := range seasonIDs {
		args[i] = id
	}
	rows, err := database.DB.Query(fmt.Sprintf(`
		SELECT season.id, COALESCE(season.season_number, 0), COALESCE(show.title, ''), COALESCE(show.poster_url, '')
		FROM medias season
		LEFT JOIN medias show ON show.id = season.parent_id
		WHERE season.id IN (%s)`, sqlPlaceholders(len(seasonIDs))), args...)
	if err != nil {
		return nil, fmt.Errorf("load shows of seasons: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int
		var show seasonShow
		if err := rows.Scan(&id, &show.number, &show.title, &show.posterURL); err != nil {
			return nil, fmt.Errorf("scan show of season: %w", err)
		}
		out[id] = show
	}
	return out, rows.Err()
}
