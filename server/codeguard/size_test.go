package codeguard

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Au-delà, un fichier porte plusieurs responsabilités : il se découpe avant
// de grossir. Voir l'ADR-0052.
const maxLines = 800

// tolerated liste les fichiers déjà au-dessus de la limite, avec le nombre de
// lignes qu'ils ne doivent plus dépasser. Elle ne fait que rétrécir : relever
// un plafond « pour que le test passe » est ce que ce test existe pour
// empêcher.
var tolerated = map[string]struct {
	ceiling int
	why     string
}{
	"indexer/metadata.go":  {1037, "le score des résultats TMDB, l'enrichissement des fiches et le rattrapage"},
	"indexer/monitor.go":   {846, "la surveillance des dossiers et la file d'après-scan"},
	"handlers/activity.go": {807, "au seuil : le prochain ajout commence par une extraction"},
}

// exempt liste les fichiers que la limite ne concerne pas.
var exempt = map[string]string{
	"database/migrations.go": "la liste des migrations : elle grandit d'une entrée par changement de schéma",
}

func lineCount(t *testing.T, path string) int {
	t.Helper()
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(source), "\n")
}

func TestNoFileOutgrowsItsSubject(t *testing.T) {
	err := filepath.WalkDir("..", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "data" || d.Name() == "downloads" {
				return filepath.SkipDir
			}
			return nil
		}
		// Les tests se lisent cas par cas : leur longueur ne dit rien.
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel := filepath.ToSlash(strings.TrimPrefix(path, ".."+string(filepath.Separator)))
		if _, ok := exempt[rel]; ok {
			return nil
		}
		lines := lineCount(t, path)
		limit := maxLines
		if known, ok := tolerated[rel]; ok {
			limit = known.ceiling
		}
		if lines > limit {
			t.Errorf("%s fait %d lignes (limite %d) : sortir dans son propre fichier le "+
				"morceau touché, puis le modifier là. emby_sync.go et federation.go "+
				"en étaient à 1 100 lignes quand il a fallu les découper.", rel, lines, limit)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestToleratedFilesOnlyShrink(t *testing.T) {
	for rel := range exempt {
		if _, err := os.Stat(filepath.Join("..", filepath.FromSlash(rel))); err != nil {
			t.Errorf("%s n'existe plus : le retirer de la liste", rel)
		}
	}
	for rel := range tolerated {
		path := filepath.Join("..", filepath.FromSlash(rel))
		if _, err := os.Stat(path); err != nil {
			t.Errorf("%s n'existe plus : le retirer de la liste", rel)
			continue
		}
		if lineCount(t, path) <= maxLines {
			t.Errorf("%s est repassé sous %d lignes : le retirer de la liste, "+
				"pour qu'il ne puisse plus y remonter", rel, maxLines)
		}
	}
}
