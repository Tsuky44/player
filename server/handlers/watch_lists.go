package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"

	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/watchlists"

	"github.com/julienschmidt/httprouter"
)

// Les listes d'un compte : « à regarder plus tard » et les siennes, partagées
// ou non avec les autres comptes du serveur (ADR-0070). Les règles tiennent
// dans le package watchlists ; ici, on décode, on traduit les erreurs et on
// joint aux éléments les fiches du serveur, avec la progression du compte qui
// lit.

const watchListBodyLimit = 16 << 10

func watchListStore() *watchlists.Store { return watchlists.New(database.DB) }

type watchListRequest struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	IsShared    bool   `json:"is_shared"`
}

// watchListItemRequest ajoute une fiche du serveur (media_id) ou un titre du
// catalogue TMDB (tmdb_id + media_type, et ce qu'il faut pour l'afficher tant
// que le serveur ne l'a pas).
type watchListItemRequest struct {
	MediaID     int    `json:"media_id"`
	TMDBID      int    `json:"tmdb_id"`
	MediaType   string `json:"media_type"`
	Title       string `json:"title"`
	PosterPath  string `json:"poster_path"`
	ReleaseDate string `json:"release_date"`
}

// writeWatchListError traduit une erreur du package en code d'état. Le
// détail d'une panne part dans le journal, pas dans la réponse.
func writeWatchListError(w http.ResponseWriter, where string, err error) {
	switch {
	case errors.Is(err, watchlists.ErrNotFound):
		writeJSONError(w, http.StatusNotFound, "Liste introuvable")
	case errors.Is(err, watchlists.ErrNotOwner):
		writeJSONError(w, http.StatusForbidden, "Seul son propriétaire modifie cette liste")
	case errors.Is(err, watchlists.ErrInvalid):
		writeJSONError(w, http.StatusBadRequest, fmt.Sprintf(
			"Nom vide ou trop long (%d caractères au plus, description %d), ou titre inconnu",
			watchlists.MaxNameRunes, watchlists.MaxDescRunes))
	case errors.Is(err, watchlists.ErrFixed):
		writeJSONError(w, http.StatusConflict, "La liste « À regarder plus tard » ne se supprime pas")
	case errors.Is(err, watchlists.ErrTooMany):
		writeJSONError(w, http.StatusConflict, fmt.Sprintf(
			"Limite atteinte (%d listes, %d titres par liste)",
			watchlists.MaxListsPerOwner, watchlists.MaxItemsPerList))
	default:
		log.Printf("%s: %v", where, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
	}
}

func writeWatchListJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// listIDParam lit un identifiant positif de l'URL.
func listIDParam(w http.ResponseWriter, ps httprouter.Params, name string) (int, bool) {
	id, err := strconv.Atoi(ps.ByName(name))
	if err != nil || id <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid id")
		return 0, false
	}
	return id, true
}

// attachWatchListMedia joint à chaque élément rattaché sa fiche du serveur,
// traduite et avec la progression du compte, en une requête pour tous. La
// fiche donne alors le titre et l'affiche : l'instantané ne sert qu'à ce que
// le serveur n'a pas.
func attachWatchListMedia(r *http.Request, userID int, items []models.WatchListItem) error {
	ids := []interface{}{}
	seen := map[int]bool{}
	for _, it := range items {
		if it.MediaID > 0 && !seen[it.MediaID] {
			seen[it.MediaID] = true
			ids = append(ids, it.MediaID)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	rows, err := database.DB.Query(fmt.Sprintf(`
		SELECT `+libraryItemColumns+`
		FROM medias m
		LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
		WHERE m.id IN (%s)`, sqlPlaceholders(len(ids))), append([]interface{}{userID}, ids...)...)
	if err != nil {
		return fmt.Errorf("load watch list media: %w", err)
	}
	defer rows.Close()
	byID := map[int]*models.HomeMediaItem{}
	var refs []*models.HomeMediaItem
	for rows.Next() {
		item, err := scanLibraryItem(rows)
		if err != nil {
			return fmt.Errorf("scan watch list media: %w", err)
		}
		ref := &item
		byID[item.ID] = ref
		refs = append(refs, ref)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("load watch list media: %w", err)
	}
	languageOf(r).items(refs...)
	for i := range items {
		media := byID[items[i].MediaID]
		if media == nil {
			// La fiche a disparu entre les deux requêtes : l'élément reste,
			// sous son instantané.
			items[i].MediaID = 0
			continue
		}
		items[i].Media = media
		items[i].Title = media.Title
		if media.PosterURL != "" {
			items[i].PosterURL = media.PosterURL
		}
		if media.ReleaseDate != "" {
			items[i].ReleaseDate = media.ReleaseDate
		}
	}
	return nil
}

// ListWatchLists renvoie les listes du compte et celles que les autres
// partagent (GET /api/lists). Avec ?media_id= ou ?tmdb_id=&media_type=,
// chacune des listes du compte dit l'élément qui porte déjà ce titre.
func ListWatchLists(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	q := r.URL.Query()
	var probe *watchlists.Probe
	if q.Get("media_id") != "" || q.Get("tmdb_id") != "" {
		mediaID, errMedia := strconv.Atoi(q.Get("media_id"))
		tmdbID, errTMDB := strconv.Atoi(q.Get("tmdb_id"))
		if errMedia != nil && errTMDB != nil {
			writeJSONError(w, http.StatusBadRequest, "Invalid media_id or tmdb_id")
			return
		}
		probe = &watchlists.Probe{MediaID: mediaID, TMDBID: tmdbID, MediaType: q.Get("media_type")}
	}
	resp, err := watchListStore().Lists(userID, probe)
	if err != nil {
		writeWatchListError(w, "ListWatchLists", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, resp)
}

// CreateWatchList crée une liste du compte (POST /api/lists).
func CreateWatchList(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	r.Body = http.MaxBytesReader(w, r.Body, watchListBodyLimit)
	var req watchListRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	list, err := watchListStore().Create(userID, watchlists.ListParams(req))
	if err != nil {
		writeWatchListError(w, "CreateWatchList", err)
		return
	}
	writeWatchListJSON(w, http.StatusCreated, list)
}

// GetWatchList renvoie une liste et ses titres (GET /api/lists/:id) : une des
// siennes, ou une liste partagée par un autre compte.
func GetWatchList(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	listID, ok := listIDParam(w, ps, "id")
	if !ok {
		return
	}
	detail, err := watchListStore().Get(userID, listID)
	if err != nil {
		writeWatchListError(w, "GetWatchList", err)
		return
	}
	if err := attachWatchListMedia(r, userID, detail.Items); err != nil {
		writeWatchListError(w, "GetWatchList", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, detail)
}

// UpdateWatchList renomme une liste, change sa description ou son partage
// (PUT /api/lists/:id).
func UpdateWatchList(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	listID, ok := listIDParam(w, ps, "id")
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, watchListBodyLimit)
	var req watchListRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	list, err := watchListStore().Update(userID, listID, watchlists.ListParams(req))
	if err != nil {
		writeWatchListError(w, "UpdateWatchList", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, list)
}

// DeleteWatchList supprime une liste du compte (DELETE /api/lists/:id).
func DeleteWatchList(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	listID, ok := listIDParam(w, ps, "id")
	if !ok {
		return
	}
	if err := watchListStore().Delete(userID, listID); err != nil {
		writeWatchListError(w, "DeleteWatchList", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

// AddWatchListItem range un titre dans une liste du compte
// (POST /api/lists/:id/items). Un titre déjà présent n'est pas doublé :
// l'élément existant revient.
func AddWatchListItem(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	listID, ok := listIDParam(w, ps, "id")
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, watchListBodyLimit)
	var req watchListItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	store := watchListStore()
	var item models.WatchListItem
	var err error
	if req.MediaID > 0 {
		item, err = store.AddServerMedia(userID, listID, req.MediaID)
	} else {
		item, err = store.AddCatalogTitle(userID, listID, watchlists.CatalogTitle{
			MediaType:   req.MediaType,
			TMDBID:      req.TMDBID,
			Title:       req.Title,
			PosterPath:  req.PosterPath,
			ReleaseDate: req.ReleaseDate,
		})
	}
	if err != nil {
		writeWatchListError(w, "AddWatchListItem", err)
		return
	}
	items := []models.WatchListItem{item}
	if err := attachWatchListMedia(r, userID, items); err != nil {
		writeWatchListError(w, "AddWatchListItem", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, items[0])
}

// RemoveWatchListItem retire un titre d'une liste du compte
// (DELETE /api/lists/:id/items/:item).
func RemoveWatchListItem(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	listID, ok := listIDParam(w, ps, "id")
	if !ok {
		return
	}
	itemID, ok := listIDParam(w, ps, "item")
	if !ok {
		return
	}
	if err := watchListStore().RemoveItem(userID, listID, itemID); err != nil {
		writeWatchListError(w, "RemoveWatchListItem", err)
		return
	}
	writeWatchListJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}
