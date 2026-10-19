package indexer

// Les corrections qu'un compte `manage_library` fait à la main sur une fiche :
// chercher la bonne entrée TMDB, ré-identifier, relancer la détection, et
// l'affiche par défaut qu'un retour en arrière rétablit (ADR-0068). Sorti de
// metadata.go, qui garde l'enrichissement automatique.

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/models"
	"project-player/server/tmdb"
)

// SearchTMDBCandidates returns up to 20 TMDB matches for a manual query, used
// by the "fix metadata" poster picker.
func SearchTMDBCandidates(query string, mediaType models.MediaType) []models.TMDBSearchCandidate {
	apiKey := tmdbAPIKey()
	query = strings.TrimSpace(query)
	if apiKey == "" || query == "" {
		return nil
	}

	endpoint := "movie"
	typeLabel := string(models.TypeMovie)
	if mediaType == models.TypeShow {
		endpoint = "tv"
		typeLabel = string(models.TypeShow)
	}

	u := fmt.Sprintf(
		"/search/%s?query=%s&language=%s",
		endpoint, url.QueryEscape(query), tmdbLanguage(),
	)
	resp, err := tmdb.Get(httpx.Standard, u)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return nil
	}
	defer resp.Body.Close()

	var out TMDBResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}

	var candidates []models.TMDBSearchCandidate
	for _, r := range out.Results {
		date := r.ReleaseDate
		if mediaType == models.TypeShow {
			date = r.FirstAirDate
		}
		candidates = append(candidates, models.TMDBSearchCandidate{
			TMDBID:    r.ID,
			Title:     tmdbDisplayTitle(r.Title, r.Name, mediaType),
			Year:      yearFromDate(date),
			Overview:  strings.TrimSpace(r.Overview),
			PosterURL: posterURLFromPath(r.PosterPath),
			MediaType: typeLabel,
		})
		if len(candidates) >= 20 {
			break
		}
	}
	return candidates
}

// RematchMediaByID re-identifies a movie/show against TMDB, overriding any
// previously stored (possibly wrong) match. When overrideTMDBID > 0 the exact
// TMDB entry is used; otherwise a fresh search runs on overrideTitle (or the
// original release filename when empty). Returns true on a successful update.
func RematchMediaByID(id int, overrideTitle string, overrideTMDBID int) bool {
	var title, mediaType, filePath string
	err := database.DB.QueryRow(
		`SELECT title, type, COALESCE(file_path, '') FROM medias WHERE id = ? AND type IN ('movie', 'show')`, id,
	).Scan(&title, &mediaType, &filePath)
	if err != nil {
		return false
	}
	mt := models.MediaType(mediaType)

	var posterURL, overview, releaseDate, displayTitle, imdbID string
	var tmdbID int

	if overrideTMDBID > 0 {
		posterURL, overview, releaseDate, displayTitle = fetchTMDBDetailsByID(overrideTMDBID, mt)
		tmdbID = overrideTMDBID
	} else if strings.TrimSpace(overrideTitle) != "" {
		identity := IdentifyFromRawName(overrideTitle, mt)
		posterURL, overview, releaseDate = identity.PosterURL, identity.Overview, identity.ReleaseDate
		displayTitle = identity.Title
		imdbID = identity.IMDbID
		if identity.Matched {
			tmdbID = identity.TMDBID
		}
	} else {
		identity := redetectIdentity(id, mt, filePath, title)
		posterURL, overview, releaseDate = identity.PosterURL, identity.Overview, identity.ReleaseDate
		displayTitle = identity.Title
		imdbID = identity.IMDbID
		if identity.Matched {
			tmdbID = identity.TMDBID
		}
	}

	if tmdbID == 0 && displayTitle == "" {
		return false
	}
	// Auto redetect/rematch must not wipe a previous good match with an unmatched result.
	if overrideTMDBID == 0 && strings.TrimSpace(overrideTitle) == "" && tmdbID == 0 {
		log.Printf("TMDB: rematch skipped for media %d — no confident identity", id)
		return false
	}
	if displayTitle == "" {
		if overrideTitle != "" {
			displayTitle = strings.TrimSpace(overrideTitle)
		} else {
			displayTitle = ReleaseDisplayTitle(enrichSearchTitle(title, filePath, mt, id), mt)
		}
	}

	// Overwrite the stored metadata unconditionally — this is an explicit fix.
	// Sauf l'affiche choisie à la main (ADR-0068) : elle reste tant que la
	// fiche TMDB est la même, et tombe avec elle sinon. SQLite évalue chaque
	// expression du SET sur la ligne d'avant la mise à jour.
	_, err = database.DB.Exec(`
		UPDATE medias SET
			title = CASE WHEN ? != '' THEN ? ELSE title END,
			poster_url = CASE WHEN poster_locked = 1 AND COALESCE(tmdb_id, 0) = ? THEN poster_url ELSE ? END,
			poster_locked = CASE WHEN COALESCE(tmdb_id, 0) = ? THEN poster_locked ELSE 0 END,
			overview = ?,
			release_date = ?,
			tmdb_id = ?,
			imdb_id = COALESCE(NULLIF(?, ''), imdb_id)
		WHERE id = ?`,
		displayTitle, displayTitle,
		tmdbID, posterURL,
		tmdbID,
		overview,
		releaseDate,
		tmdbID,
		imdbID,
		id,
	)
	if err != nil {
		log.Printf("TMDB: failed to rematch media %d: %v", id, err)
		return false
	}
	log.Printf("TMDB: rematched %s %q (id=%d, tmdb=%d)", mediaType, displayTitle, id, tmdbID)
	return true
}

func redetectIdentity(id int, mt models.MediaType, filePath, storedTitle string) IdentityMatch {
	filePath = strings.TrimSpace(filePath)
	switch mt {
	case models.TypeMovie:
		if filePath != "" {
			// Parent of the file is used as library root fallback; folder-first still applies
			// when the movie sits in its own directory.
			return IdentifyMovie(filePath, filepath.Dir(filepath.Dir(filePath)))
		}
	case models.TypeShow:
		folder, _ := ShowLocalLibraryHint(id)
		if folder != "" {
			showFolder := ""
			if sample := sampleShowEpisodePath(id); sample != "" {
				cur := filepath.Dir(sample)
				for i := 0; i < 5; i++ {
					base := filepath.Base(cur)
					lower := strings.ToLower(base)
					if !strings.HasPrefix(lower, "season ") && !strings.HasPrefix(lower, "saison ") && !looksLikeEpisodeReleaseFolder(base) {
						showFolder = cur
						break
					}
					parent := filepath.Dir(cur)
					if parent == cur {
						break
					}
					cur = parent
				}
			}
			return IdentifyShow(showFolder, folder)
		}
	}
	return IdentifyFromRawName(enrichSearchTitle(storedTitle, filePath, mt, id), mt)
}

// RedetectMediaByID re-runs TMDB identification from local file/folder names and
// overwrites the stored match (same as rematch without manual pick). For shows,
// episode metadata is refreshed from the new TMDB id.
func RedetectMediaByID(id int) bool {
	if !RematchMediaByID(id, "", 0) {
		return false
	}
	var mediaType string
	if err := database.DB.QueryRow(`SELECT type FROM medias WHERE id = ?`, id).Scan(&mediaType); err != nil {
		return true
	}
	if mediaType == string(models.TypeShow) {
		RefreshAllSeasonsEpisodesFromTMDB(id)
	}
	return true
}

// DefaultPosterURL est l'affiche que l'enrichissement automatique retiendrait
// pour cette fiche TMDB : celle de la langue des métadonnées, sinon l'anglaise.
// Vide quand TMDB ne répond pas.
func DefaultPosterURL(tmdbID int, mediaType models.MediaType) string {
	posterURL, _, _, _ := fetchTMDBDetailsByID(tmdbID, mediaType)
	return posterURL
}
