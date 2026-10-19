package models

import "time"

// Les listes d'un compte : « à regarder plus tard » et les siennes, partagées
// ou non avec les autres comptes du serveur. Voir ADR-0070.

const (
	// WatchListKindWatchLater est la liste que chaque compte a d'office. Elle
	// ne se renomme ni ne se supprime ; l'app l'affiche sous son nom traduit.
	WatchListKindWatchLater = "watch_later"
	// WatchListKindCustom est une liste faite par le compte.
	WatchListKindCustom = "custom"
)

// WatchListOwner est le compte à qui appartient une liste.
type WatchListOwner struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
}

// WatchList est le résumé d'une liste : ce que montrent la page des listes et
// la feuille « Ajouter à une liste ».
type WatchList struct {
	ID          int            `json:"id"`
	Kind        string         `json:"kind"`
	Name        string         `json:"name"`
	Description string         `json:"description"`
	IsShared    bool           `json:"is_shared"`
	IsMine      bool           `json:"is_mine"`
	Owner       WatchListOwner `json:"owner"`
	ItemCount   int            `json:"item_count"`
	// Posters sont les affiches des derniers ajouts, quatre au plus, pour la
	// vignette de la liste.
	Posters   []string  `json:"posters"`
	UpdatedAt time.Time `json:"updated_at"`
	// ContainsItemID est l'élément de cette liste qui porte le titre demandé
	// par ?media_id= ou ?tmdb_id= (0 s'il n'y est pas). Absent sans question.
	ContainsItemID *int `json:"contains_item_id,omitempty"`
}

// WatchListItem est un film ou une série d'une liste, sur le serveur ou pas.
type WatchListItem struct {
	ID          int       `json:"id"`
	MediaType   string    `json:"media_type"`
	TMDBID      int       `json:"tmdb_id"`
	Title       string    `json:"title"`
	PosterURL   string    `json:"poster_url"`
	ReleaseDate string    `json:"release_date"`
	AddedAt     time.Time `json:"added_at"`
	// MediaID est la fiche du serveur à laquelle l'élément se rattache, 0
	// quand le serveur n'a pas (ou plus) ce titre.
	MediaID int `json:"media_id"`
	// Media est cette fiche, avec la progression du compte qui lit la liste.
	Media *HomeMediaItem `json:"media,omitempty"`
}

// WatchListDetail est une liste et son contenu, du plus récent ajout au plus
// ancien.
type WatchListDetail struct {
	WatchList
	Items []WatchListItem `json:"items"`
}

// WatchListsResponse range les listes du compte et celles que les autres
// partagent.
type WatchListsResponse struct {
	Mine   []WatchList `json:"mine"`
	Shared []WatchList `json:"shared"`
}
