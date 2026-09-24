package models

import "time"

// MediaShare est un lien de partage public tel que son créateur le voit
// (GET /api/shares, POST /api/shares). Voir ADR-0037.
type MediaShare struct {
	ID        int    `json:"id"`
	MediaID   int    `json:"media_id"`
	MediaType string `json:"media_type"`
	// Title est le film, ou la série pour un épisode ; Subtitle porte alors
	// « S01E02 · Titre de l'épisode ».
	Title       string     `json:"title"`
	Subtitle    string     `json:"subtitle,omitempty"`
	PosterURL   string     `json:"poster_url,omitempty"`
	HasPassword bool       `json:"has_password"`
	SingleUse   bool       `json:"single_use"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
	// Claimed : un navigateur a réservé ce lien à usage unique.
	Claimed    bool       `json:"claimed"`
	ConsumedAt *time.Time `json:"consumed_at,omitempty"`
	Views      int        `json:"views"`
	// Status vaut "active", "expired" ou "watched".
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	// Code n'est rendu qu'à la création : le serveur n'en garde que
	// l'empreinte, il ne pourra plus le redonner.
	Code string `json:"code,omitempty"`
}

// SharedMedia est ce qu'un visiteur sans compte apprend d'un lien
// (POST /api/shared/info). Tant qu'un mot de passe est exigé, le média reste
// anonyme : Title et les suivants sont vides.
type SharedMedia struct {
	NeedsPassword bool       `json:"needs_password"`
	SingleUse     bool       `json:"single_use"`
	ExpiresAt     *time.Time `json:"expires_at,omitempty"`
	MediaType     string     `json:"media_type,omitempty"`
	Title         string     `json:"title,omitempty"`
	Subtitle      string     `json:"subtitle,omitempty"`
	PosterURL     string     `json:"poster_url,omitempty"`
	Duration      int        `json:"duration,omitempty"`
}

// SharedMediaAccess est la réponse à l'ouverture d'un lien
// (POST /api/shared/open) : un ticket de lecture du média, et le jeton du
// navigateur à présenter pour le renouveler.
type SharedMediaAccess struct {
	Media             SharedMedia `json:"media"`
	MediaID           int         `json:"media_id"`
	Ticket            string      `json:"ticket"`
	ExpiresAt         time.Time   `json:"expires_at"`
	RenewAfterSeconds int         `json:"renew_after_seconds"`
	Viewer            string      `json:"viewer"`
}

// SharedMediaRenewal répond à POST /api/shared/renew.
type SharedMediaRenewal struct {
	ExpiresAt time.Time `json:"expires_at"`
}

// SharedMediaProgress répond à POST /api/shared/progress. Consumed dit que le
// lien, à usage unique, est désormais détruit.
type SharedMediaProgress struct {
	Consumed bool `json:"consumed"`
}
