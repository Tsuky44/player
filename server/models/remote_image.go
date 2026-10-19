package models

// RemoteImage est une affiche proposée pour une fiche par un site d'images
// (ADR-0068). URL est ce qui sera enregistré si on la choisit ; ThumbURL, une
// version réduite pour la grille du choix.
type RemoteImage struct {
	URL      string `json:"url"`
	ThumbURL string `json:"thumb_url"`
	// Source : "tmdb" ou "fanart".
	Source string `json:"source"`
	// Language : code ISO 639-1 du texte de l'affiche, vide quand elle n'en a
	// pas.
	Language string  `json:"language,omitempty"`
	Width    int     `json:"width,omitempty"`
	Height   int     `json:"height,omitempty"`
	Rating   float64 `json:"rating,omitempty"`
	Votes    int     `json:"votes,omitempty"`
}

// RemotePosters répond à GET /api/media/:id/images/posters.
type RemotePosters struct {
	// Current : l'affiche enregistrée aujourd'hui.
	Current string `json:"current,omitempty"`
	// Locked : Current a été choisie à la main et l'enrichissement automatique
	// ne la remplace plus.
	Locked bool `json:"locked"`
	// FanartEnabled : une clé Fanart.tv est réglée, ses affiches sont dans la
	// liste. L'app peut sinon suggérer d'en ajouter une.
	FanartEnabled bool          `json:"fanart_enabled"`
	Images        []RemoteImage `json:"images"`
}
