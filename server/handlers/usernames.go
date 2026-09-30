package handlers

import (
	"database/sql"

	"project-player/server/database"
)

// Un nom d'utilisateur ne distingue pas la casse : « Mathis », « mathis » et
// « MATHIS » désignent le même compte. Sur un téléviseur ou un téléphone, la
// majuscule automatique du clavier suffisait à faire refuser une connexion au
// bon mot de passe.
//
// La colonne garde la graphie choisie à l'inscription, c'est elle qu'on
// affiche. Seules les comparaisons l'ignorent, et elles passent toutes par ce
// fichier (voir TestUsernameLookupsIgnoreCase).
//
// COLLATE NOCASE ne replie que l'ASCII : « Élise » et « élise » restent deux
// noms, ce qui vaut mieux qu'un repli approximatif qui confondrait deux comptes.

// rowQuerier est ce que *sql.DB et *sql.Tx ont en commun pour ces lectures.
type rowQuerier interface {
	QueryRow(query string, args ...any) *sql.Row
}

// usernameTaken dit si un compte porte déjà ce nom, à la casse près.
func usernameTaken(q rowQuerier, username string) (bool, error) {
	var taken bool
	err := q.QueryRow(
		"SELECT EXISTS(SELECT 1 FROM users WHERE username = ? COLLATE NOCASE)", username,
	).Scan(&taken)
	return taken, err
}

// pendingAccessRequestFor dit si une demande d'accès attend déjà sous ce nom,
// à la casse près.
func pendingAccessRequestFor(username string) (bool, error) {
	var pending bool
	err := database.DB.QueryRow(`
		SELECT EXISTS(
			SELECT 1 FROM access_requests
			WHERE username = ? COLLATE NOCASE
			  AND status = 'pending' AND expires_at > datetime('now'))`,
		username,
	).Scan(&pending)
	return pending, err
}

// findLoginAccount retrouve le compte à ouvrir pour ce nom.
//
// Une base antérieure à cette règle peut contenir deux comptes qui ne
// diffèrent que par la casse : la graphie exacte l'emporte alors, pour que
// chacun garde l'accès au sien. Renvoie sql.ErrNoRows si aucun ne correspond.
func findLoginAccount(username string) (userID int, passwordHash string, err error) {
	err = database.DB.QueryRow(`
		SELECT id, password_hash FROM users
		WHERE username = ? COLLATE NOCASE
		ORDER BY username = ? DESC, id
		LIMIT 1`,
		username, username,
	).Scan(&userID, &passwordHash)
	return userID, passwordHash, err
}
