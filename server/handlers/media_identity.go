package handlers

import (
	"encoding/json"
	"net/http"
	"os"

	"github.com/julienschmidt/httprouter"
	"project-player/server/database"
	"project-player/server/models"
)

// Media identities are cached by clients before a source goes offline. An
// episode's identity always uses its show's TMDB ID and numbering.
type ContentIdentity struct {
	Type    string `json:"type"`
	TMDBID  int    `json:"tmdb_id"`
	Season  int    `json:"season_number"`
	Episode int    `json:"episode_number"`
}

func (c ContentIdentity) valid() bool {
	return c.TMDBID > 0 && ((c.Type == "movie" && c.Season == 0 && c.Episode == 0) ||
		(c.Type == "episode" && c.Season >= 0 && c.Episode > 0))
}

func GetMediaIdentities(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	rows, err := database.DB.Query(portableMedia)
	if err != nil {
		http.Error(w, "Unable to read identities", 500)
		return
	}
	defer rows.Close()
	identities := map[int]ContentIdentity{}
	for rows.Next() {
		var id int
		var identity ContentIdentity
		if err := rows.Scan(&id, &identity.Type, &identity.TMDBID, &identity.Season, &identity.Episode); err != nil {
			http.Error(w, "Unable to read identities", 500)
			return
		}
		identities[id] = identity
	}
	if rows.Err() != nil {
		http.Error(w, "Unable to read identities", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(identities)
}

// ResolveMedia returns only a locally readable copy of the exact content.
// A title match is not enough, and a catalog entry without a file is not a relay.
func ResolveMedia(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	var identity ContentIdentity
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&identity); err != nil || !identity.valid() {
		http.Error(w, "Invalid content identity", 400)
		return
	}
	rows, err := database.DB.Query(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
 SELECT `+mediaColumns+`, COALESCE(p.current_position_seconds, 0), COALESCE(p.is_finished, 0)
 FROM medias m JOIN content c ON m.id = c.id
 LEFT JOIN progressions p ON p.media_id = m.id AND p.user_id = ?
 WHERE c.type = ? AND c.tmdb = ? AND c.season = ? AND c.episode = ? ORDER BY m.id`,
		userID, identity.Type, identity.TMDBID, identity.Season, identity.Episode)
	if err != nil {
		http.Error(w, "Unable to resolve media", 500)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var position int
		var finished bool
		media, err := scanMedia(rows, &position, &finished)
		if err != nil {
			http.Error(w, "Unable to read media", 500)
			return
		}
		file, err := os.Open(media.FilePath)
		if err != nil {
			continue
		}
		info, statErr := file.Stat()
		file.Close()
		if statErr != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			continue
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(struct {
			models.Media
			Position int  `json:"current_position_seconds"`
			Finished bool `json:"is_finished"`
		}{media, position, finished})
		return
	}
	if rows.Err() != nil {
		http.Error(w, "Unable to read media", 500)
		return
	}
	http.Error(w, "No available copy", 404)
}
