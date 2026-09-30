package handlers

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"project-player/server/database"

	"golang.org/x/crypto/bcrypt"
)

func insertUserWithPassword(t *testing.T, username, password string) {
	t.Helper()
	hash, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if _, err := database.DB.Exec(
		`INSERT INTO users (username, password_hash) VALUES (?, ?)`, username, string(hash),
	); err != nil {
		t.Fatalf("insert user %q: %v", username, err)
	}
}

func loginStatus(username, password string) int {
	rec := httptest.NewRecorder()
	Login(rec, httptest.NewRequest(http.MethodPost, "/api/auth/login",
		strings.NewReader(`{"username":"`+username+`","password":"`+password+`"}`)), nil)
	return rec.Code
}

func TestLoginIgnoresUsernameCase(t *testing.T) {
	setupAuthDB(t)
	insertUserWithPassword(t, "Mathis", "secret")

	for _, typed := range []string{"Mathis", "mathis", "MATHIS", " mathis "} {
		if code := loginStatus(typed, "secret"); code != http.StatusOK {
			t.Errorf("login as %q: status %d, want 200", typed, code)
		}
	}
	if code := loginStatus("mathis", "wrong"); code != http.StatusUnauthorized {
		t.Errorf("wrong password: status %d, want 401", code)
	}
}

// Une base d'avant la règle peut contenir « Lea » et « lea » : chacun doit
// garder l'accès au sien.
func TestLoginPrefersExactCaseAmongLegacyDuplicates(t *testing.T) {
	setupAuthDB(t)
	insertUserWithPassword(t, "Lea", "first")
	insertUserWithPassword(t, "lea", "second")

	if code := loginStatus("Lea", "first"); code != http.StatusOK {
		t.Errorf("Lea: status %d, want 200", code)
	}
	if code := loginStatus("lea", "second"); code != http.StatusOK {
		t.Errorf("lea: status %d, want 200", code)
	}
}

func TestUsernameTakenIgnoresCase(t *testing.T) {
	setupAuthDB(t)
	insertUserWithPassword(t, "Mathis", "secret")

	taken, err := usernameTaken(database.DB, "MATHIS")
	if err != nil {
		t.Fatal(err)
	}
	if !taken {
		t.Fatal("« MATHIS » must collide with the existing « Mathis »")
	}
}

// Garde : toute comparaison de nom d'utilisateur passe par usernames.go, sans
// quoi une nouvelle requête réintroduit la casse et refuse « mathis » à
// « Mathis ».
func TestUsernameLookupsIgnoreCase(t *testing.T) {
	bare := regexp.MustCompile(`username\s*=\s*\?`)
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") || file == "usernames.go" {
			continue
		}
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if bare.Match(src) {
			t.Errorf("%s compare un nom d'utilisateur en SQL : passe par usernameTaken, "+
				"pendingAccessRequestFor ou findLoginAccount (usernames.go), qui ignorent la casse", file)
		}
	}
}
