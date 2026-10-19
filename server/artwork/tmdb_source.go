package artwork

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"

	"project-player/server/httpx"
	"project-player/server/models"
	"project-player/server/tmdb"
)

const tmdbImageBase = "https://image.tmdb.org/t/p/"

// tmdbPosterSize est la taille enregistrée : celle des affiches que
// l'indexeur pose déjà (posterURLFromPath), pour qu'une affiche choisie pèse
// le même poids dans les grilles qu'une affiche par défaut.
const (
	tmdbPosterSize = "w500"
	tmdbThumbSize  = "w185"
)

func tmdbEndpoint(mediaType models.MediaType) string {
	if mediaType == models.TypeShow {
		return "tv"
	}
	return "movie"
}

// tmdbPosters lit /images de la fiche. TMDB ne renvoie que les langues
// demandées : celle de l'interface, l'anglais et les affiches sans texte
// ("null").
func tmdbPosters(ctx context.Context, mediaType models.MediaType, tmdbID int, language string) ([]models.RemoteImage, error) {
	languages := "en,null"
	if language != "" && language != "en" {
		languages = language + "," + languages
	}
	path := fmt.Sprintf("/%s/%d/images?include_image_language=%s",
		tmdbEndpoint(mediaType), tmdbID, url.QueryEscape(languages))
	resp, err := tmdb.GetContext(ctx, httpx.Standard, path)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("images: HTTP %d", resp.StatusCode)
	}
	return parseTMDBPosters(resp.Body)
}

func parseTMDBPosters(body io.Reader) ([]models.RemoteImage, error) {
	var payload struct {
		Posters []struct {
			FilePath    string  `json:"file_path"`
			Language    *string `json:"iso_639_1"`
			VoteAverage float64 `json:"vote_average"`
			VoteCount   int     `json:"vote_count"`
			Width       int     `json:"width"`
			Height      int     `json:"height"`
		} `json:"posters"`
	}
	if err := json.NewDecoder(body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("images: %w", err)
	}
	images := make([]models.RemoteImage, 0, len(payload.Posters))
	for _, p := range payload.Posters {
		if p.FilePath == "" {
			continue
		}
		language := ""
		if p.Language != nil {
			language = *p.Language
		}
		images = append(images, models.RemoteImage{
			URL:      tmdbImageBase + tmdbPosterSize + p.FilePath,
			ThumbURL: tmdbImageBase + tmdbThumbSize + p.FilePath,
			Source:   "tmdb",
			Language: language,
			Width:    p.Width,
			Height:   p.Height,
			Rating:   p.VoteAverage,
			Votes:    p.VoteCount,
		})
	}
	return images, nil
}
