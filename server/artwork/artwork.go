// Package artwork propose et enregistre l'affiche d'un film ou d'une série, à
// la façon d'Emby : les affiches que TMDB et Fanart.tv connaissent pour la
// même œuvre, parmi lesquelles un compte `manage_library` choisit (ADR-0068).
//
// Le choix est retenu par une marque, medias.poster_locked, que
// l'enrichissement automatique respecte : sans elle, le prochain rattrapage
// remettait l'affiche de TMDB.
package artwork

import (
	"context"
	"log"
	"sort"
	"sync"

	"project-player/server/models"
	"project-player/server/safego"
)

// maxPosters borne la liste : au-delà, personne ne fait défiler la grille, et
// chaque vignette est une image à charger sur une télévision.
const maxPosters = 120

// Posters liste les affiches connues pour une fiche TMDB, celles dans la
// langue de l'interface d'abord. Une source qui ne répond pas est journalisée
// et laissée de côté : l'autre suffit à proposer un choix.
func Posters(ctx context.Context, mediaType models.MediaType, tmdbID int, language string) []models.RemoteImage {
	var wg sync.WaitGroup
	var fromTMDB, fromFanart []models.RemoteImage
	wg.Add(2)
	go safego.Run("artwork: affiches TMDB", func() {
		defer wg.Done()
		images, err := tmdbPosters(ctx, mediaType, tmdbID, language)
		if err != nil {
			log.Printf("artwork: TMDB %s %d: %v", mediaType, tmdbID, err)
		}
		fromTMDB = images
	})
	go safego.Run("artwork: affiches Fanart.tv", func() {
		defer wg.Done()
		images, err := fanartPosters(ctx, mediaType, tmdbID)
		if err != nil {
			log.Printf("artwork: Fanart.tv %s %d: %v", mediaType, tmdbID, err)
		}
		fromFanart = images
	})
	wg.Wait()

	images := append(fromTMDB, fromFanart...)
	rank(images, language)
	if len(images) > maxPosters {
		images = images[:maxPosters]
	}
	return images
}

// rank range les affiches comme on les cherche : dans la langue de
// l'interface, puis sans texte, puis en anglais, puis le reste ; dans chaque
// groupe, les plus appréciées d'abord.
func rank(images []models.RemoteImage, language string) {
	group := func(img models.RemoteImage) int {
		switch img.Language {
		case language:
			return 0
		case "":
			return 1
		case "en":
			return 2
		}
		return 3
	}
	sort.SliceStable(images, func(i, j int) bool {
		gi, gj := group(images[i]), group(images[j])
		if gi != gj {
			return gi < gj
		}
		if images[i].Votes != images[j].Votes {
			return images[i].Votes > images[j].Votes
		}
		return images[i].Rating > images[j].Rating
	})
}
