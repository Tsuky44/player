package models

import "time"

// Announcement est le message qu'un administrateur adresse à tous les comptes
// du serveur. Chaque publication a un nouvel identifiant : c'est ce qui la
// remontre à ceux qui avaient lu la précédente. Voir ADR-0069.
type Announcement struct {
	ID        int       `json:"id"`
	Title     string    `json:"title"`
	Message   string    `json:"message"`
	CreatedAt time.Time `json:"created_at"`
}
