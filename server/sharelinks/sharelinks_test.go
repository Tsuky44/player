package sharelinks

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"project-player/server/database"
)

// newTestStore ouvre une vraie base (migrations comprises) avec un compte et
// un film, et un Store dont l'horloge est pilotée par le test.
func newTestStore(t *testing.T) (*Store, *time.Time) {
	t.Helper()
	db, err := database.InitDB(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`INSERT INTO users (id, username, password_hash) VALUES (1, 'owner', 'x')`); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO medias (id, type, title, file_path, duration) VALUES (7, 'movie', 'Film', '/film.mkv', 6000)`); err != nil {
		t.Fatalf("insert media: %v", err)
	}
	now := time.Date(2026, 9, 24, 20, 0, 0, 0, time.UTC)
	store := New(db)
	store.now = func() time.Time { return now }
	return store, &now
}

func mustCreate(t *testing.T, s *Store, p CreateParams) string {
	t.Helper()
	if p.UserID == 0 {
		p.UserID = 1
	}
	if p.MediaID == 0 {
		p.MediaID = 7
	}
	code, _, err := s.Create(p)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return code
}

func TestCodeIsOnlyStoredAsDigest(t *testing.T) {
	s, _ := newTestStore(t)
	code := mustCreate(t, s, CreateParams{Password: "secret"})

	var stored, password string
	if err := s.db.QueryRow(`SELECT code_digest, password_hash FROM media_shares`).Scan(&stored, &password); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stored, code) || stored != digest(code) {
		t.Fatalf("code stored in clear: %q", stored)
	}
	if password == "" || strings.Contains(password, "secret") {
		t.Fatalf("password not hashed: %q", password)
	}
}

func TestPasswordIsRequiredToOpen(t *testing.T) {
	s, _ := newTestStore(t)
	code := mustCreate(t, s, CreateParams{Password: "secret"})

	for _, wrong := range []string{"", "Secret", "secret "} {
		if _, _, err := s.Open(code, wrong, ""); !errors.Is(err, ErrPassword) {
			t.Fatalf("Open(%q) = %v, want ErrPassword", wrong, err)
		}
	}
	if _, _, err := s.Open(code, "secret", ""); err != nil {
		t.Fatalf("Open with the right password: %v", err)
	}
}

func TestUnknownCodeIsNotFound(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreate(t, s, CreateParams{})
	for _, code := range []string{"", "short", strings.Repeat("A", 22), "../../etc/passwd......"} {
		if _, _, err := s.Open(code, "", ""); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Open(%q) = %v, want ErrNotFound", code, err)
		}
	}
}

// Un lien à usage unique appartient au premier navigateur qui l'ouvre : lui
// peut recharger la page, un autre appareil est refusé.
func TestSingleUseLinkIsClaimedByFirstViewer(t *testing.T) {
	s, _ := newTestStore(t)
	code := mustCreate(t, s, CreateParams{SingleUse: true})

	_, viewer, err := s.Open(code, "", "")
	if err != nil || viewer == "" {
		t.Fatalf("first open: viewer=%q err=%v", viewer, err)
	}
	if _, again, err := s.Open(code, "", viewer); err != nil || again != viewer {
		t.Fatalf("reload by the same viewer: viewer=%q err=%v", again, err)
	}
	if _, _, err := s.Open(code, "", ""); !errors.Is(err, ErrClaimed) {
		t.Fatalf("second browser: %v, want ErrClaimed", err)
	}
	if _, err := s.Authorize(code, "someone-else-token-xxx"); !errors.Is(err, ErrClaimed) {
		t.Fatalf("Authorize by another browser: %v, want ErrClaimed", err)
	}
}

// Vu, le lien est détruit pour tout le monde ; le navigateur qui l'a vu garde
// le temps du générique, pas plus.
func TestSingleUseLinkIsDestroyedOnceWatched(t *testing.T) {
	s, now := newTestStore(t)
	code := mustCreate(t, s, CreateParams{SingleUse: true})
	share, viewer, err := s.Open(code, "", "")
	if err != nil {
		t.Fatal(err)
	}

	if consumed, err := s.Consume(share.ID); err != nil || !consumed {
		t.Fatalf("Consume: %v %v", consumed, err)
	}
	if consumed, _ := s.Consume(share.ID); consumed {
		t.Fatal("a link is consumed only once")
	}
	if _, _, err := s.Open(code, "", viewer); !errors.Is(err, ErrGone) {
		t.Fatalf("reopen after watched: %v, want ErrGone", err)
	}
	if _, err := s.Authorize(code, viewer); err != nil {
		t.Fatalf("viewer during the grace period: %v", err)
	}
	*now = now.Add(ConsumedGrace)
	if _, err := s.Authorize(code, viewer); !errors.Is(err, ErrGone) {
		t.Fatalf("viewer after the grace period: %v, want ErrGone", err)
	}
}

// Un lien permanent n'est jamais consommé, et s'ouvre sur autant d'appareils
// qu'on veut.
func TestReusableLinkSurvivesWatching(t *testing.T) {
	s, _ := newTestStore(t)
	code := mustCreate(t, s, CreateParams{})
	share, first, err := s.Open(code, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if consumed, _ := s.Consume(share.ID); consumed {
		t.Fatal("a reusable link must not be consumed")
	}
	if _, second, err := s.Open(code, "", ""); err != nil || second == first {
		t.Fatalf("second browser: viewer=%q err=%v", second, err)
	}
	reloaded, err := s.Find(code)
	if err != nil || reloaded.Views != 2 {
		t.Fatalf("views = %d, %v; want 2", reloaded.Views, err)
	}
}

func TestLinkExpires(t *testing.T) {
	s, now := newTestStore(t)
	code := mustCreate(t, s, CreateParams{LifetimeHours: 24})
	_, viewer, err := s.Open(code, "", "")
	if err != nil {
		t.Fatal(err)
	}
	*now = now.Add(24 * time.Hour)
	if _, _, err := s.Open(code, "", viewer); !errors.Is(err, ErrGone) {
		t.Fatalf("open after expiry: %v, want ErrGone", err)
	}
	if _, err := s.Authorize(code, viewer); !errors.Is(err, ErrGone) {
		t.Fatalf("renew after expiry: %v, want ErrGone", err)
	}
}

func TestCreateRejectsInvalidParameters(t *testing.T) {
	s, _ := newTestStore(t)
	for name, p := range map[string]CreateParams{
		"lifetime hors liste":    {UserID: 1, MediaID: 7, LifetimeHours: 5},
		"mot de passe trop long": {UserID: 1, MediaID: 7, Password: strings.Repeat("a", 73)},
		"sans média":             {UserID: 1},
	} {
		if _, _, err := s.Create(p); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s: %v, want ErrInvalid", name, err)
		}
	}
}

func TestDeleteIsScopedToOwner(t *testing.T) {
	s, _ := newTestStore(t)
	if _, err := s.db.Exec(`INSERT INTO users (id, username, password_hash) VALUES (2, 'other', 'x')`); err != nil {
		t.Fatal(err)
	}
	code := mustCreate(t, s, CreateParams{})
	share, err := s.Find(code)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(share.ID, 2); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete by another account: %v, want ErrNotFound", err)
	}
	if err := s.Delete(share.ID, 1); err != nil {
		t.Fatalf("delete by owner: %v", err)
	}
	if _, err := s.Find(code); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted link still found: %v", err)
	}
}
