package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// writeETaggedJSON répond v en JSON avec un ETag, ou 304 quand le client a
// déjà exactement ce document.
//
// Les listes de la médiathèque renvoient tout le catalogue — chaque film avec
// son résumé — à chaque ouverture de l'écran, sur un téléphone comme sur un
// téléviseur, alors qu'il change rarement entre deux visites. L'empreinte est
// celle du document lui-même : elle couvre la progression du compte qui s'y
// trouve, sans compteur de version à tenir à jour dans chaque écriture de
// l'indexeur. La requête et l'encodage restent faits ; ce qu'on économise,
// c'est le transfert et le décodage côté client.
func writeETaggedJSON(w http.ResponseWriter, r *http.Request, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		log.Printf("writeETaggedJSON: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	sum := sha256.Sum256(body)
	etag := `"` + hex.EncodeToString(sum[:16]) + `"`

	// private : le document dépend du compte. no-cache : à revalider à chaque
	// fois, ce que l'ETag rend peu coûteux.
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Add("Vary", "Authorization")
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

func etagMatches(ifNoneMatch, etag string) bool {
	for _, candidate := range strings.Split(ifNoneMatch, ",") {
		candidate = strings.TrimPrefix(strings.TrimSpace(candidate), "W/")
		if candidate == etag || candidate == "*" {
			return true
		}
	}
	return false
}
