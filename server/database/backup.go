package database

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// migrationBackupsKept est le nombre de copies d'avant-migration gardées à
// côté de la base. Les plus anciennes sont effacées.
const migrationBackupsKept = 3

const migrationBackupSuffix = ".bak"

// backupBeforeMigrating copie la base avant qu'une migration ne la modifie.
//
// Une migration ne se défait pas, et la base porte ce qu'aucun scan ne
// reconstruit : les comptes, la progression de chacun, l'historique. Sans
// copie, une migration qui tourne mal — ou une version qu'on voudrait
// simplement quitter — ne laissait rien vers quoi revenir.
//
// `VACUUM INTO` écrit une copie cohérente sans arrêter la base, WAL compris.
// nextID est la première migration à venir : elle nomme le fichier, pour dire
// de quel schéma il est la photo.
func backupBeforeMigrating(db *sql.DB, dbPath string, nextID int) (string, error) {
	if dbPath == "" || dbPath == ":memory:" || strings.HasPrefix(dbPath, "file:") {
		return "", nil
	}
	target := fmt.Sprintf("%s.pre-%04d-%s%s", dbPath, nextID,
		time.Now().UTC().Format("20060102T150405"), migrationBackupSuffix)
	if _, err := db.Exec(`VACUUM INTO ?`, target); err != nil {
		_ = os.Remove(target)
		return "", fmt.Errorf("backup before migration %04d: %w", nextID, err)
	}
	pruneMigrationBackups(dbPath, migrationBackupsKept)
	return target, nil
}

// pruneMigrationBackups ne garde que les keep copies les plus récentes. Leur
// nom finit par un horodatage : l'ordre alphabétique est celui du temps.
func pruneMigrationBackups(dbPath string, keep int) {
	matches, err := filepath.Glob(dbPath + ".pre-*" + migrationBackupSuffix)
	if err != nil || len(matches) <= keep {
		return
	}
	sort.Slice(matches, func(i, j int) bool {
		return backupStamp(matches[i]) < backupStamp(matches[j])
	})
	for _, old := range matches[:len(matches)-keep] {
		if err := os.Remove(old); err != nil {
			log.Printf("Database: could not remove old backup %s: %v", old, err)
		}
	}
}

// backupStamp isole l'horodatage d'un nom de copie.
func backupStamp(path string) string {
	name := strings.TrimSuffix(path, migrationBackupSuffix)
	if i := strings.LastIndex(name, "-"); i >= 0 {
		return name[i+1:]
	}
	return name
}

// mainDatabaseFile demande à la connexion le fichier qu'elle a ouvert, plutôt
// que de se fier à un chemin gardé à côté : c'est cette base-là qui va migrer.
// Vide pour une base en mémoire.
func mainDatabaseFile(db *sql.DB) (string, error) {
	rows, err := db.Query(`PRAGMA database_list`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return "", err
		}
		if name == "main" {
			return file, nil
		}
	}
	return "", rows.Err()
}
