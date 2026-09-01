package handlers

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// EnrichMediaMetadata fetches TMDB data for one movie/show (POST /api/media/:id/metadata/enrich).
func EnrichMediaMetadata(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	if !indexer.EnrichMediaByID(mediaID) {
		http.Error(w, `{"error": "No metadata found on TMDB"}`, http.StatusNotFound)
		return
	}

	writeMediaByID(w, mediaID)
}

// writeMediaByID reloads a media row and writes it as the response. The three
// metadata endpoints (enrich, redetect, rematch) all answer with the refreshed
// record, and each carried its own copy of this read.
func writeMediaByID(w http.ResponseWriter, mediaID int) {
	m, err := scanMedia(database.DB.QueryRow(
		`SELECT `+mediaColumns+` FROM medias m WHERE m.id = ?`, mediaID))
	if err != nil {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(m)
}

// GetMediaDetails returns rich, Emby-style catalog details for a movie/show
// (GET /api/media/:id/details). Local library data (id, title, poster, overview,
// release date) is merged with live TMDB metadata (cast, genres, rating,
// backdrop, crew). Degrades gracefully to local-only when TMDB is unavailable.
func GetMediaDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	var mediaType string
	err = database.DB.QueryRow(`SELECT type FROM medias WHERE id = ?`, mediaID).Scan(&mediaType)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}
	mt := models.MediaType(mediaType)
	if mt == models.TypeShow {
		mediaID = indexer.ResolveCanonicalShowID(mediaID)
	} else if mt == models.TypeMovie {
		mediaID = indexer.ResolveCanonicalMovieID(mediaID)
	}

	var title string
	var filePath, posterURL, overview, releaseDate sql.NullString
	var tmdbID sql.NullInt64
	var duration int
	err = database.DB.QueryRow(`
		SELECT type, title, file_path, COALESCE(duration, 0), poster_url, overview, release_date, tmdb_id
		FROM medias WHERE id = ? AND type IN ('movie', 'show')`, mediaID,
	).Scan(&mediaType, &title, &filePath, &duration, &posterURL, &overview, &releaseDate, &tmdbID)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error": "Media not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("MediaDetails error: failed to load media %d: %v", mediaID, err)
		http.Error(w, `{"error": "Internal database error"}`, http.StatusInternalServerError)
		return
	}

	mt = models.MediaType(mediaType)

	// Make sure we have a TMDB id to query the live catalog.
	// when missing (e.g. freshly indexed titles).
	if !tmdbID.Valid || tmdbID.Int64 <= 0 {
		if indexer.EnrichMediaByID(mediaID) {
			var refreshed sql.NullInt64
			_ = database.DB.QueryRow("SELECT tmdb_id FROM medias WHERE id = ?", mediaID).Scan(&refreshed)
			tmdbID = refreshed
		}
	}

	// Base payload from the local record — always returned even if TMDB fails.
	details := models.MediaDetails{
		ID:          mediaID,
		Type:        mt,
		Title:       title,
		Duration:    duration,
		Overview:    overview.String,
		PosterURL:   posterURL.String,
		ReleaseDate: releaseDate.String,
	}
	if filePath.Valid && filePath.String != "" {
		details.FileName = filepath.Base(filePath.String)
	} else if mt == models.TypeShow {
		folder, epFile := indexer.ShowLocalLibraryHint(mediaID)
		details.LocalFolder = folder
		details.LocalEpisodeFile = epFile
		if folder != "" {
			details.FileName = folder
		} else if epFile != "" {
			details.FileName = epFile
		}
	}
	if tmdbID.Valid {
		details.TMDBID = int(tmdbID.Int64)
	}

	if catalog := indexer.FetchMediaCatalogDetails(details.TMDBID, mt); catalog != nil {
		mergeCatalogDetails(&details, catalog)
		details.SimilarTitles = similarCatalogItems(catalog, details.TMDBID)
	}

	json.NewEncoder(w).Encode(details)
}

// maxSimilarTitles caps the "Titres similaires" rail. TMDB hands back 20 per
// list and two lists; a rail nobody scrolls past a dozen cards does not need
// forty posters.
const maxSimilarTitles = 20

// similarCatalogItems folds TMDB's recommendations and similar lists into the
// rail shown at the bottom of a detail page. Recommendations lead — TMDB ranks
// those by what people actually watched next — and every entry is tagged with
// its local library id, so an owned title opens its library page while the rest
// open the request page.
func similarCatalogItems(catalog *models.MediaDetails, selfTMDBID int) []models.CatalogItem {
	items := make([]models.CatalogItem, 0, maxSimilarTitles)
	seen := map[int]bool{selfTMDBID: true}

	for _, list := range [][]models.RelatedMedia{catalog.Recommendations, catalog.Similar} {
		for _, rel := range list {
			if len(items) >= maxSimilarTitles {
				break
			}
			// A card with no poster is a grey rectangle in a poster rail.
			if rel.ID <= 0 || rel.PosterURL == "" || seen[rel.ID] {
				continue
			}
			seen[rel.ID] = true
			year := ""
			if len(rel.ReleaseDate) >= 4 {
				year = rel.ReleaseDate[:4]
			}
			items = append(items, models.CatalogItem{
				TMDBID:      rel.ID,
				Title:       rel.Title,
				PosterURL:   rel.PosterURL,
				BackdropURL: rel.BackdropURL,
				Year:        year,
				MediaType:   string(rel.Type),
				Rating:      rel.VoteAverage,
			})
		}
	}

	attachLocalIDs(items)
	return items
}

// mergeCatalogDetails overlays live TMDB catalog data onto the local record,
// keeping the local id/poster while filling in the rich fields.
func mergeCatalogDetails(dst *models.MediaDetails, src *models.MediaDetails) {
	if src.Title != "" {
		dst.Title = src.Title
	}
	dst.OriginalTitle = src.OriginalTitle
	dst.Tagline = src.Tagline
	if src.Overview != "" {
		dst.Overview = src.Overview
	}
	// Keep the library poster when set — avoids stale TMDB artwork on wrong duplicate rows.
	if dst.PosterURL == "" && src.PosterURL != "" {
		dst.PosterURL = src.PosterURL
	}
	dst.BackdropURL = src.BackdropURL
	dst.LogoURL = src.LogoURL
	if src.ReleaseDate != "" {
		dst.ReleaseDate = src.ReleaseDate
	}
	if src.Runtime > 0 {
		dst.Runtime = src.Runtime
	}
	dst.Status = src.Status
	dst.VoteAverage = src.VoteAverage
	dst.Genres = src.Genres
	dst.Studios = src.Studios
	dst.Countries = src.Countries
	dst.OriginalLang = src.OriginalLang
	dst.Director = src.Director
	dst.Writers = src.Writers
	dst.Cast = src.Cast
	dst.Collection = src.Collection
	dst.NumberOfSeasons = src.NumberOfSeasons
	dst.NumberOfEpisodes = src.NumberOfEpisodes
}

// RedetectMediaMetadata re-runs automatic TMDB matching from local paths
// (POST /api/media/:id/metadata/redetect).
func RedetectMediaMetadata(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	if !indexer.RedetectMediaByID(mediaID) {
		http.Error(w, `{"error": "No matching title found on TMDB"}`, http.StatusNotFound)
		return
	}

	writeMediaByID(w, mediaID)
}

// GetPersonDetails returns an actor/crew profile with filmography
// (GET /api/person/:id). The :id is a TMDB person id. Filmography entries are
// tagged with their local library id when the title is owned.
func GetPersonDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	personID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || personID <= 0 {
		http.Error(w, `{"error": "Invalid person ID"}`, http.StatusBadRequest)
		return
	}

	person := indexer.FetchPersonDetails(personID)
	if person == nil {
		http.Error(w, `{"error": "Person not found"}`, http.StatusNotFound)
		return
	}

	attachLocalIDs(person.Filmography)
	json.NewEncoder(w).Encode(person)
}

// GetCollectionDetails returns a movie saga with its ordered parts
// (GET /api/collection/:id). The :id is a TMDB collection id.
func GetCollectionDetails(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	collectionID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || collectionID <= 0 {
		http.Error(w, `{"error": "Invalid collection ID"}`, http.StatusBadRequest)
		return
	}

	collection := indexer.FetchCollectionDetails(collectionID)
	if collection == nil {
		http.Error(w, `{"error": "Collection not found"}`, http.StatusNotFound)
		return
	}

	attachLocalIDs(collection.Parts)
	json.NewEncoder(w).Encode(collection)
}

// attachLocalIDs fills in the LocalID of catalog items that exist in the
// library, matched by TMDB id + type. Items not owned keep LocalID == 0.
func attachLocalIDs(items []models.CatalogItem) {
	if len(items) == 0 {
		return
	}

	// Collect the TMDB ids to resolve in a single query.
	tmdbIDs := make([]interface{}, 0, len(items))
	seen := map[int]bool{}
	for _, it := range items {
		if it.TMDBID > 0 && !seen[it.TMDBID] {
			seen[it.TMDBID] = true
			tmdbIDs = append(tmdbIDs, it.TMDBID)
		}
	}
	if len(tmdbIDs) == 0 {
		return
	}

	placeholders := strings.TrimRight(strings.Repeat("?,", len(tmdbIDs)), ",")
	query := fmt.Sprintf(
		"SELECT id, type, tmdb_id FROM medias WHERE type IN ('movie','show') AND tmdb_id IN (%s)",
		placeholders,
	)
	rows, err := database.DB.Query(query, tmdbIDs...)
	if err != nil {
		log.Printf("attachLocalIDs query error: %v", err)
		return
	}
	defer rows.Close()

	// map[tmdbID]map[mediaType]localID
	owned := map[int]map[string]int{}
	for rows.Next() {
		var id, tmdbID int
		var mediaType string
		if err := rows.Scan(&id, &mediaType, &tmdbID); err != nil {
			continue
		}
		if owned[tmdbID] == nil {
			owned[tmdbID] = map[string]int{}
		}
		owned[tmdbID][mediaType] = id
	}

	for i := range items {
		if byType, ok := owned[items[i].TMDBID]; ok {
			if localID, ok := byType[items[i].MediaType]; ok {
				items[i].LocalID = localID
			}
		}
	}
}

// SearchTMDBMetadata returns TMDB candidates for a manual query
// (GET /api/tmdb/search?query=...&type=movie|show), used by the poster picker.
func SearchTMDBMetadata(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	query := strings.TrimSpace(r.URL.Query().Get("query"))
	if query == "" {
		http.Error(w, `{"error": "query is required"}`, http.StatusBadRequest)
		return
	}

	mediaType := models.TypeMovie
	if t := r.URL.Query().Get("type"); t == "show" || t == "tv" {
		mediaType = models.TypeShow
	}

	results := indexer.SearchTMDBCandidates(query, mediaType)
	if results == nil {
		results = []models.TMDBSearchCandidate{}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"results": results})
}

// RematchMediaMetadata re-identifies a movie/show against TMDB, letting the user
// fix a wrong match (POST /api/media/:id/metadata/rematch?title=...&tmdb_id=...).
func RematchMediaMetadata(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	mediaID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || mediaID <= 0 {
		http.Error(w, `{"error": "Invalid media ID"}`, http.StatusBadRequest)
		return
	}

	overrideTitle := strings.TrimSpace(r.URL.Query().Get("title"))
	overrideTMDBID := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("tmdb_id")); raw != "" {
		if v, convErr := strconv.Atoi(raw); convErr == nil {
			overrideTMDBID = v
		}
	}

	if !indexer.RematchMediaByID(mediaID, overrideTitle, overrideTMDBID) {
		http.Error(w, `{"error": "No matching title found on TMDB"}`, http.StatusNotFound)
		return
	}

	writeMediaByID(w, mediaID)
}
