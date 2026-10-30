package mediahub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
)

// La recherche interactive (ADR-0098) : lister les releases que les
// indexeurs offrent pour un film, une saison ou un épisode, et en envoyer une
// au téléchargement. MediaHub juge le droit interactive_search et choisit qui
// cherche, sorraa ou Radarr/Sonarr, comme pour les demandes ; OnyxHub n'a rien
// de tel.

// Release est une proposition d'un indexeur, telle que MediaHub la rend. Avec
// sorraa (Manager « sorraa »), ID est un jeton de 30 minutes, il n'y a pas
// d'adresse de téléchargement et le moteur de sorraa a jugé la release
// (Accepted, Rejections) ; avec Radarr/Sonarr (« arr »), ID est le guid de
// l'indexeur et la release porte son adresse.
type Release struct {
	ID          string  `json:"id"`
	GUID        string  `json:"guid"`
	Title       string  `json:"title"`
	Size        int64   `json:"size"`
	Indexer     string  `json:"indexer"`
	IndexerID   int     `json:"indexerId"`
	PublishDate string  `json:"publishDate"`
	Seeders     *int    `json:"seeders"`
	Leechers    *int    `json:"leechers"`
	Age         float64 `json:"age"`
	DownloadURL *string `json:"downloadUrl"`
	MagnetURL   *string `json:"magnetUrl"`
	Protocol    string  `json:"protocol"`
	// Accepted est le verdict de sorraa ; nil avec Radarr/Sonarr, qui ne jugent
	// pas avant l'envoi.
	Accepted *bool `json:"accepted"`
	// Rejections dit, en français, pourquoi sorraa ne la prendrait pas d'office.
	Rejections []string `json:"rejections"`
	// FormatScore est la somme des scores des formats personnalisés (sorraa).
	FormatScore int `json:"customFormatScore"`
}

// ReleaseList est ce que MediaHub rend d'une recherche : Manager dit qui a
// cherché (« sorraa » ou « arr »).
type ReleaseList struct {
	Manager  string    `json:"manager"`
	Releases []Release `json:"releases"`
}

// ReleaseTarget désigne ce qu'on cherche. Season et Episode valent nil pour un
// film ; Season seule vise la saison entière.
type ReleaseTarget struct {
	TMDBID    int    `json:"tmdbId"`
	MediaType string `json:"mediaType"`
	Season    *int   `json:"season,omitempty"`
	Episode   *int   `json:"episode,omitempty"`
}

// Valid dit si la cible a un sens : un film n'a ni saison ni épisode, et un
// épisode ne va pas sans sa saison.
func (t ReleaseTarget) Valid() bool {
	if t.TMDBID <= 0 || (t.MediaType != "movie" && t.MediaType != "tv") {
		return false
	}
	if t.Season != nil && *t.Season < 0 || t.Episode != nil && *t.Episode < 0 {
		return false
	}
	if t.MediaType == "movie" {
		return t.Season == nil && t.Episode == nil
	}
	return t.Episode == nil || t.Season != nil
}

// Releases rend les propositions des indexeurs pour la cible, au nom du
// compte. ErrUnsupported dit que le compagnon n'a pas la recherche interactive
// (OnyxHub, ou un MediaHub d'avant la route).
func (c Client) Releases(ctx context.Context, as Account, target ReleaseTarget) (ReleaseList, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return ReleaseList{}, err
	}
	if dialect != DialectV1 {
		return ReleaseList{}, ErrUnsupported
	}
	query := url.Values{"tmdbId": {strconv.Itoa(target.TMDBID)}, "type": {target.MediaType}}
	if target.Season != nil {
		query.Set("season", strconv.Itoa(*target.Season))
	}
	if target.Episode != nil {
		query.Set("episode", strconv.Itoa(*target.Episode))
	}
	raw, err := c.call(ctx, http.MethodGet, V1Path+"/releases", as, query, nil)
	if isRouteMissing(err) {
		return ReleaseList{}, ErrUnsupported
	}
	if err != nil {
		return ReleaseList{}, err
	}
	var list ReleaseList
	if err := json.Unmarshal(raw, &list); err != nil {
		return ReleaseList{}, fmt.Errorf("mediahub: decode releases: %w", err)
	}
	if list.Releases == nil {
		list.Releases = []Release{}
	}
	for i := range list.Releases {
		if list.Releases[i].Rejections == nil {
			list.Releases[i].Rejections = []string{}
		}
	}
	return list, nil
}

// GrabRequest est le choix d'une release : la cible, et la proposition telle
// que la liste la rendait.
type GrabRequest struct {
	ReleaseTarget
	Release GrabbedRelease `json:"release"`
}

// GrabbedRelease est la part d'une [Release] que MediaHub relaie : avec sorraa
// ID suffit (le jeton de la liste, sorraa a gardé la release), avec
// Radarr/Sonarr il faut aussi l'adresse, que Sonarr ne connaît pas. GUID est
// l'ancien nom de ID.
type GrabbedRelease struct {
	ID          string  `json:"id,omitempty"`
	GUID        string  `json:"guid,omitempty"`
	IndexerID   int     `json:"indexerId"`
	Title       string  `json:"title"`
	DownloadURL *string `json:"downloadUrl,omitempty"`
	MagnetURL   *string `json:"magnetUrl,omitempty"`
	Protocol    string  `json:"protocol,omitempty"`
	PublishDate string  `json:"publishDate,omitempty"`
	Indexer     string  `json:"indexer,omitempty"`
	Size        int64   `json:"size,omitempty"`
}

// Valid dit si la demande nomme une cible et une release. Qu'il faille ou non
// une adresse dépend du gestionnaire, que seul MediaHub connaît : il refuse une
// release de Radarr/Sonarr sans adresse.
func (g GrabRequest) Valid() bool {
	r := g.Release
	return g.ReleaseTarget.Valid() && (r.ID != "" || r.GUID != "") && r.Title != "" && r.IndexerID >= 0
}

// Grab envoie la release choisie au téléchargement, par MediaHub, au nom du
// compte. L'erreur de MediaHub (403, 410 pour un jeton périmé, 502…) remonte en
// *StatusError.
func (c Client) Grab(ctx context.Context, as Account, grab GrabRequest) error {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return err
	}
	if dialect != DialectV1 {
		return ErrUnsupported
	}
	body, err := json.Marshal(grab)
	if err != nil {
		return fmt.Errorf("mediahub: encode release: %w", err)
	}
	_, err = c.call(ctx, http.MethodPost, V1Path+"/releases", as, nil, body)
	if isRouteMissing(err) {
		return ErrUnsupported
	}
	return err
}

// isRouteMissing : un MediaHub d'avant la route répond 404 sans corps JSON de
// MediaHub. Une 404 de MediaHub porte { code } ; on ne s'y trompe que sur la
// route elle-même.
func isRouteMissing(err error) bool {
	var status *StatusError
	if !errors.As(err, &status) || status.Status != http.StatusNotFound {
		return false
	}
	return !json.Valid(status.Body)
}
