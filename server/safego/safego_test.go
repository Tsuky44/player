package safego

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestRunSurvivesAPanicAndStillRunsInnerDefers(t *testing.T) {
	released := false
	done := make(chan struct{})
	go func() {
		defer close(done)
		Run("test", func() {
			defer func() { released = true }()
			panic("boom")
		})
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run never returned")
	}
	if !released {
		t.Error("the task's own defer did not run: its \"running\" flag would stay set")
	}
}

func TestForeverRestartsAPanickingLoopAndStopsWhenItReturns(t *testing.T) {
	old := restartDelay
	restartDelay = time.Millisecond
	defer func() { restartDelay = old }()

	runs := 0
	done := make(chan struct{})
	go func() {
		defer close(done)
		Forever("test", func() {
			runs++
			if runs < 3 {
				panic("transient")
			}
		})
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Forever never returned after the loop completed")
	}
	if runs != 3 {
		t.Errorf("loop ran %d times, want 3 (two panics, one clean return)", runs)
	}
}

// Garde : toute goroutine du serveur passe par ce package. Une goroutine nue
// qui panique arrête le processus entier, et coupe toutes les lectures en
// cours. Écrire `go safego.Run(…)`, `go safego.Forever(…)`, ou poser
// `defer safego.Recover(…)` en première ligne de la goroutine.
func TestEveryGoroutineIsGuarded(t *testing.T) {
	// Justifiées une à une : elles ne font qu'attendre ou rendre une valeur.
	allowed := map[string]string{
		"main.go: go func() { served <- server.ListenAndServe() }()": "rend l'erreur d'écoute au main, qui s'arrête dessus",
	}
	launch := regexp.MustCompile(`^\s*go\s+\S`)

	err := filepath.WalkDir("..", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "safego" || d.Name() == "data" || d.Name() == "downloads" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(strings.ReplaceAll(string(source), "\r\n", "\n"), "\n")
		for i, line := range lines {
			if !launch.MatchString(line) {
				continue
			}
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "go safego.") {
				continue
			}
			if _, ok := allowed[filepath.Base(path)+": "+trimmed]; ok {
				continue
			}
			if i+1 < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i+1]), "defer safego.Recover(") {
				continue
			}
			t.Errorf("%s:%d lance une goroutine sans garde (%s) : une panique y arrêterait "+
				"tout le serveur. Passer par safego.", path, i+1, trimmed)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
