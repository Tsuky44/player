package database

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
)

// SessionTokenDigest est ce que la table sessions garde d'un jeton de
// connexion : son empreinte SHA-256, en hexadécimal.
//
// Les jetons y étaient en clair. Une copie de la base — une sauvegarde, un
// volume Docker partagé, un disque revendu — donnait donc de quoi se connecter
// à chaque compte sans connaître un seul mot de passe. L'empreinte suffit pour
// retrouver une session à partir du jeton présenté, et ne permet pas l'inverse.
// Pas de sel ni de dérivation lente : le jeton est 256 bits d'aléa, il n'y a
// rien à deviner par dictionnaire. Les tickets de lecture font déjà de même
// (playbackauth).
func SessionTokenDigest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// hashStoredSessionTokens remplace chaque jeton en clair par son empreinte.
// Migration 13 : exécutée une seule fois, quand toutes les lignes sont encore
// en clair.
func hashStoredSessionTokens(tx *sql.Tx) error {
	rows, err := tx.Query(`SELECT rowid, token FROM sessions`)
	if err != nil {
		return fmt.Errorf("read sessions: %w", err)
	}
	type row struct {
		id    int64
		token string
	}
	var all []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.token); err != nil {
			rows.Close()
			return fmt.Errorf("scan session: %w", err)
		}
		all = append(all, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("read sessions: %w", err)
	}
	for _, r := range all {
		if _, err := tx.Exec(`UPDATE sessions SET token = ? WHERE rowid = ?`,
			SessionTokenDigest(r.token), r.id); err != nil {
			return fmt.Errorf("hash session %d: %w", r.id, err)
		}
	}
	return nil
}
