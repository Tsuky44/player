package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"

	"project-player/server/indexer"
	"project-player/server/libraries"
	"project-player/server/models"
	"project-player/server/safego"

	"github.com/julienschmidt/httprouter"
)

// Les bibliothèques du serveur (ADR-0058) : un dossier, un nom libre, un type.

// libraryRequest is the body of POST and PUT /api/libraries. Kind is only read
// at creation.
type libraryRequest struct {
	Name string         `json:"name"`
	Kind libraries.Kind `json:"kind"`
	Path string         `json:"path"`
}

const libraryBodyLimit = 4 << 10

// ListLibraries returns the libraries in the order they were created
// (GET /api/libraries). Their folder is the server's disk layout: it is only
// sent to an account that could change it.
func ListLibraries(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	libs, err := libraries.List()
	if err != nil {
		log.Printf("ListLibraries: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
		return
	}
	user, err := LoadUser(userID)
	if err != nil || !user.Permissions.Has(models.PermManageSettings) {
		for i := range libs {
			libs[i].Path = ""
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(libs)
}

// CreateLibrary declares a library and starts indexing it (POST /api/libraries).
func CreateLibrary(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	req, ok := decodeLibraryRequest(w, r)
	if !ok {
		return
	}
	lib, err := libraries.Create(req.Name, req.Kind, req.Path)
	if err != nil {
		writeLibraryError(w, "CreateLibrary", err)
		return
	}
	// Une analyse déjà en cours ne la verra pas : le moniteur relit la liste
	// chaque minute et parcourt alors le nouveau dossier.
	indexer.ScanMedia(libraries.Current())

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(lib)
}

// UpdateLibrary renames a library or points it at another folder
// (PUT /api/libraries/:id). A folder that changes takes its catalog with it:
// what was indexed under the old one is forgotten, the new one is scanned.
func UpdateLibrary(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid library ID")
		return
	}
	req, ok := decodeLibraryRequest(w, r)
	if !ok {
		return
	}
	previous, updated, err := libraries.Update(id, req.Name, req.Path)
	if err != nil {
		writeLibraryError(w, "UpdateLibrary", err)
		return
	}
	if updated.Path != previous.Path {
		forgetLibraryFolderAsync(previous.Path)
		indexer.ScanMedia(libraries.Current())
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(updated)
}

// DeleteLibrary removes a library and its catalog (DELETE /api/libraries/:id).
// The files on disk are never touched.
func DeleteLibrary(w http.ResponseWriter, r *http.Request, ps httprouter.Params, _ int) {
	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid library ID")
		return
	}
	lib, err := libraries.Delete(id)
	if err != nil {
		writeLibraryError(w, "DeleteLibrary", err)
		return
	}
	forgetLibraryFolderAsync(lib.Path)
	w.WriteHeader(http.StatusNoContent)
}

// forgetLibraryFolderAsync retire du catalogue ce qui était indexé sous un
// dossier qui n'est plus celui d'une bibliothèque. En tâche de fond : il attend
// la fin d'une analyse en cours, qui peut durer.
func forgetLibraryFolderAsync(path string) {
	go safego.Run("handlers.forgetLibraryFolder", func() {
		if _, err := indexer.ForgetMediaUnder(path, libraries.Current()); err != nil {
			log.Printf("forgetLibraryFolder: %v", err)
		}
	})
}

func decodeLibraryRequest(w http.ResponseWriter, r *http.Request) (libraryRequest, bool) {
	var req libraryRequest
	r.Body = http.MaxBytesReader(w, r.Body, libraryBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return libraryRequest{}, false
	}
	return req, true
}

// writeLibraryError répond l'erreur d'une écriture. Les messages sont ceux que
// l'app affiche tels quels sous le formulaire.
func writeLibraryError(w http.ResponseWriter, context string, err error) {
	switch {
	case errors.Is(err, libraries.ErrNotFound):
		writeJSONError(w, http.StatusNotFound, "Bibliothèque introuvable")
	case errors.Is(err, libraries.ErrInvalidName):
		writeJSONError(w, http.StatusBadRequest,
			"Donnez un nom à la bibliothèque ("+strconv.Itoa(libraries.MaxNameLength)+" caractères au plus)")
	case errors.Is(err, libraries.ErrInvalidKind):
		writeJSONError(w, http.StatusBadRequest, "Type de bibliothèque inconnu")
	case errors.Is(err, libraries.ErrInvalidPath):
		writeJSONError(w, http.StatusBadRequest, "Indiquez le chemin complet du dossier, tel que le serveur le voit")
	case errors.Is(err, libraries.ErrPathNotFound):
		writeJSONError(w, http.StatusBadRequest, "Ce dossier n'existe pas sur le serveur")
	case errors.Is(err, libraries.ErrPathTaken):
		writeJSONError(w, http.StatusConflict, "Ce dossier est déjà celui d'une autre bibliothèque")
	default:
		log.Printf("%s: %v", context, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal database error")
	}
}

// libraryFilter lit le paramètre `library` d'une liste du catalogue. Absent,
// la liste couvre tout le serveur — ce que lisent la recherche et les apps
// d'avant les bibliothèques. ok est faux quand la réponse est déjà écrite.
func libraryFilter(w http.ResponseWriter, r *http.Request) (lib *libraries.Library, ok bool) {
	raw := strings.TrimSpace(r.URL.Query().Get("library"))
	if raw == "" {
		return nil, true
	}
	id, err := strconv.Atoi(raw)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid library ID")
		return nil, false
	}
	found, err := libraries.Get(id)
	if err != nil {
		writeLibraryError(w, "libraryFilter", err)
		return nil, false
	}
	return &found, true
}
