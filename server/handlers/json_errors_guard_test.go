package handlers

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestNoJSONErrorGoesOutAsPlainText scanne les handlers : une erreur JSON
// écrite avec http.Error part en text/plain, et l'app, qui ne décode alors pas
// le corps, affiche un message générique à la place de celui du serveur.
// writeJSONError est la seule façon d'en écrire une.
func TestNoJSONErrorGoesOutAsPlainText(t *testing.T) {
	pattern := regexp.MustCompile(`http\.Error\([^,]+, ` + "`" + `\{`)
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(data), "\n") {
			if pattern.MatchString(line) {
				t.Errorf("%s:%d writes a JSON error as text/plain — use writeJSONError", file, i+1)
			}
		}
	}
}
