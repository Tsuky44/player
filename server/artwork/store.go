package artwork

import (
	"database/sql"
	"errors"
	"fmt"
	"net/url"

	"project-player/server/database"
	"project-player/server/indexer"
	"project-player/server/models"
)

var (
	// ErrNotFound : aucun film ni série sous cet identifiant.
	ErrNotFound = errors.New("artwork: media not found")
	// ErrHostNotAllowed : l'adresse ne vient pas d'un site que le serveur
	// propose.
	ErrHostNotAllowed = errors.New("artwork: image host not allowed")
)

// allowedHosts : seuls les sites dont Posters tire ses affiches. L'adresse
// enregistrée est chargée par chaque app de la maison ; une adresse libre en
// ferait un moyen de leur faire joindre n'importe quel hôte.
var allowedHosts = map[string]bool{
	"image.tmdb.org":   true,
	"assets.fanart.tv": true,
}

// Allowed dit si une adresse d'affiche peut être enregistrée.
func Allowed(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil {
		return false
	}
	return allowedHosts[u.Host]
}

// Target est la fiche dont on change l'affiche.
type Target struct {
	ID     int
	Type   models.MediaType
	TMDBID int
	Poster string
	Locked bool
}

// Load lit un film ou une série. Les saisons et les épisodes n'ont pas
// d'affiche à eux : ils portent celle de leur série.
func Load(mediaID int) (Target, error) {
	t := Target{ID: mediaID}
	var mediaType string
	err := database.DB.QueryRow(`
		SELECT type, COALESCE(tmdb_id, 0), COALESCE(poster_url, ''), poster_locked
		FROM medias WHERE id = ? AND type IN ('movie', 'show')`, mediaID,
	).Scan(&mediaType, &t.TMDBID, &t.Poster, &t.Locked)
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrNotFound
	}
	if err != nil {
		return t, fmt.Errorf("artwork: load %d: %w", mediaID, err)
	}
	t.Type = models.MediaType(mediaType)
	return t, nil
}

// Choose enregistre l'affiche choisie et pose la marque qui la protège de
// l'enrichissement automatique.
func Choose(mediaID int, posterURL string) error {
	if !Allowed(posterURL) {
		return ErrHostNotAllowed
	}
	return apply(mediaID, posterURL, true)
}

// Reset lève la marque et remet l'affiche que TMDB donne par défaut. Quand
// TMDB ne répond pas, la marque tombe seule : le prochain rattrapage remettra
// l'affiche par défaut.
func Reset(mediaID int) error {
	t, err := Load(mediaID)
	if err != nil {
		return err
	}
	if t.TMDBID > 0 {
		if poster := indexer.DefaultPosterURL(t.TMDBID, t.Type); poster != "" {
			return apply(mediaID, poster, false)
		}
	}
	if _, err := database.DB.Exec(`UPDATE medias SET poster_locked = 0 WHERE id = ?`, mediaID); err != nil {
		return fmt.Errorf("artwork: unlock %d: %w", mediaID, err)
	}
	return nil
}

// apply écrit l'affiche d'un film ou d'une série. Les saisons et épisodes
// d'une série qui portaient son ancienne affiche (backfillEpisodePosters) la
// suivent ; ceux qui ont leur propre image la gardent.
func apply(mediaID int, posterURL string, locked bool) error {
	tx, err := database.DB.Begin()
	if err != nil {
		return fmt.Errorf("artwork: begin: %w", err)
	}
	defer tx.Rollback()

	var mediaType, previous string
	err = tx.QueryRow(`
		SELECT type, COALESCE(poster_url, '') FROM medias
		WHERE id = ? AND type IN ('movie', 'show')`, mediaID,
	).Scan(&mediaType, &previous)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("artwork: read %d: %w", mediaID, err)
	}

	if _, err := tx.Exec(`UPDATE medias SET poster_url = ?, poster_locked = ? WHERE id = ?`,
		posterURL, locked, mediaID); err != nil {
		return fmt.Errorf("artwork: write %d: %w", mediaID, err)
	}
	if mediaType == string(models.TypeShow) && previous != "" && previous != posterURL {
		if _, err := tx.Exec(`
			UPDATE medias SET poster_url = ?
			WHERE poster_url = ?
			  AND (parent_id = ? OR parent_id IN (
				SELECT id FROM medias WHERE parent_id = ? AND type = 'season'))`,
			posterURL, previous, mediaID, mediaID); err != nil {
			return fmt.Errorf("artwork: follow %d: %w", mediaID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("artwork: commit %d: %w", mediaID, err)
	}
	return nil
}
