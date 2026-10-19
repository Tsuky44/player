package artwork

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"project-player/server/config"
	"project-player/server/httpx"
	"project-player/server/models"
	"project-player/server/tmdb"
)

const fanartBase = "https://webservice.fanart.tv/v3"

// fanartPosters lit les affiches de Fanart.tv. Sans clé réglée, la source
// est simplement absente. Fanart.tv range les films par identifiant TMDB,
// mais les séries par identifiant TheTVDB, que TMDB fournit.
func fanartPosters(ctx context.Context, mediaType models.MediaType, tmdbID int) ([]models.RemoteImage, error) {
	key := config.FanartAPIKey()
	if key == "" {
		return nil, nil
	}
	path := "/movies/" + strconv.Itoa(tmdbID)
	if mediaType == models.TypeShow {
		tvdbID, err := tvdbIDOf(ctx, tmdbID)
		if err != nil || tvdbID == 0 {
			return nil, err
		}
		path = "/tv/" + strconv.Itoa(tvdbID)
	}

	// La clé passe par l'en-tête, pas par l'URL : une erreur de net/http cite
	// l'URL entière, et elle finirait dans le journal (ADR-0050).
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fanartBase+path, nil)
	if err != nil {
		return nil, fmt.Errorf("GET %s: invalid request", path)
	}
	req.Header.Set("api-key", key)
	resp, err := httpx.Standard.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		// Fanart.tv ne connaît pas l'œuvre : rien à proposer, pas une panne.
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	return parseFanartPosters(resp.Body)
}

func tvdbIDOf(ctx context.Context, tmdbID int) (int, error) {
	resp, err := tmdb.GetContext(ctx, httpx.Standard, fmt.Sprintf("/tv/%d/external_ids", tmdbID))
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("external_ids: HTTP %d", resp.StatusCode)
	}
	var ids struct {
		TVDBID *int `json:"tvdb_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ids); err != nil {
		return 0, fmt.Errorf("external_ids: %w", err)
	}
	if ids.TVDBID == nil {
		return 0, nil
	}
	return *ids.TVDBID, nil
}

func parseFanartPosters(body io.Reader) ([]models.RemoteImage, error) {
	type fanartImage struct {
		URL  string `json:"url"`
		Lang string `json:"lang"`
		// Fanart.tv écrit ses compteurs en texte.
		Likes string `json:"likes"`
	}
	var payload struct {
		MoviePoster []fanartImage `json:"movieposter"`
		TVPoster    []fanartImage `json:"tvposter"`
	}
	if err := json.NewDecoder(body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("fanart: %w", err)
	}
	all := append(payload.MoviePoster, payload.TVPoster...)
	images := make([]models.RemoteImage, 0, len(all))
	for _, p := range all {
		// Les adresses anciennes sont en http : l'app ne charge que du https.
		full := strings.Replace(strings.TrimSpace(p.URL), "http://", "https://", 1)
		if !strings.HasPrefix(full, "https://") {
			continue
		}
		language := p.Lang
		// "00" : l'affiche n'a pas de texte.
		if language == "00" {
			language = ""
		}
		likes, err := strconv.Atoi(p.Likes)
		if err != nil {
			likes = 0 // un compteur absent ou illisible ne classe pas l'affiche
		}
		images = append(images, models.RemoteImage{
			URL: full,
			// Fanart.tv sert une version réduite de chaque image sous /preview/.
			ThumbURL: strings.Replace(full, "/fanart/", "/preview/", 1),
			Source:   "fanart",
			Language: language,
			Votes:    likes,
		})
	}
	return images, nil
}
