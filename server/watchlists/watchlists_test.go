package watchlists

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

const (
	alice = 1
	bob   = 2
)

// newTestStore ouvre une vraie base (migrations comprises) avec deux comptes,
// un film identifié par TMDB (603), un film sans identité TMDB et un épisode.
func newTestStore(t *testing.T) *Store {
	t.Helper()
	db, err := database.InitDB(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	for _, stmt := range []string{
		`INSERT INTO users (id, username, password_hash) VALUES (1, 'alice', 'x'), (2, 'bob', 'x')`,
		`INSERT INTO medias (id, type, title, file_path, tmdb_id, poster_url) VALUES (10, 'movie', 'Matrix', '/m.mkv', 603, '/posters/matrix.jpg')`,
		`INSERT INTO medias (id, type, title, file_path, poster_url) VALUES (11, 'movie', 'Vacances', '/v.mkv', '/posters/v.jpg')`,
		`INSERT INTO medias (id, type, title, file_path) VALUES (12, 'episode', 'Pilote', '/e.mkv')`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	now := time.Date(2026, 10, 19, 20, 0, 0, 0, time.UTC)
	store := New(db)
	store.now = func() time.Time {
		now = now.Add(time.Millisecond)
		return now
	}
	return store
}

func watchLaterOf(t *testing.T, s *Store, owner int) models.WatchList {
	t.Helper()
	lists, err := s.Lists(owner, nil)
	if err != nil {
		t.Fatalf("Lists: %v", err)
	}
	for _, l := range lists.Mine {
		if l.Kind == models.WatchListKindWatchLater {
			return l
		}
	}
	t.Fatalf("no watch later list for %d", owner)
	return models.WatchList{}
}

func mustCreate(t *testing.T, s *Store, owner int, name string, shared bool) models.WatchList {
	t.Helper()
	l, err := s.Create(owner, ListParams{Name: name, IsShared: shared})
	if err != nil {
		t.Fatalf("Create %q: %v", name, err)
	}
	return l
}

func TestEveryAccountHasExactlyOneWatchLaterList(t *testing.T) {
	s := newTestStore(t)
	for i := 0; i < 3; i++ {
		watchLaterOf(t, s, alice)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM watch_lists WHERE owner_id = ? AND kind = 'watch_later'`, alice).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("watch later lists = %d, want 1", n)
	}
	// Relire ses listes ne consomme pas d'identifiant : la liste suivante
	// prend celui d'après.
	recos := mustCreate(t, s, alice, "Mes recos", false)
	if recos.ID != 2 {
		t.Fatalf("next list id = %d, want 2", recos.ID)
	}
	lists, err := s.Lists(alice, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(lists.Mine) != 2 || lists.Mine[0].Kind != models.WatchListKindWatchLater {
		t.Fatalf("watch later must come first: %+v", lists.Mine)
	}
}

func TestWatchLaterKeepsItsNameAndCannotBeDeleted(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	updated, err := s.Update(alice, later.ID, ListParams{Name: "Autre chose", IsShared: true})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if updated.Name != watchLaterName || !updated.IsShared {
		t.Fatalf("watch later keeps its name, takes the sharing: %+v", updated)
	}
	if err := s.Delete(alice, later.ID); !errors.Is(err, ErrFixed) {
		t.Fatalf("Delete watch later: %v, want ErrFixed", err)
	}
}

// Une liste privée n'existe pas pour les autres ; partagée, elle se lit mais
// ne se modifie que par son propriétaire.
func TestOthersReadSharedListsOnlyAndNeverWrite(t *testing.T) {
	s := newTestStore(t)
	private := mustCreate(t, s, alice, "Secret", false)
	shared := mustCreate(t, s, alice, "Mes recos", true)

	if _, err := s.Get(bob, private.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("private list for bob: %v, want ErrNotFound", err)
	}
	if _, err := s.AddServerMedia(bob, private.ID, 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("write to private list: %v, want ErrNotFound", err)
	}
	if _, err := s.Get(bob, shared.ID); err != nil {
		t.Fatalf("shared list for bob: %v", err)
	}
	if _, err := s.AddServerMedia(bob, shared.ID, 10); !errors.Is(err, ErrNotOwner) {
		t.Fatalf("write to shared list: %v, want ErrNotOwner", err)
	}
	if err := s.Delete(bob, shared.ID); !errors.Is(err, ErrNotOwner) {
		t.Fatalf("delete shared list: %v, want ErrNotOwner", err)
	}

	lists, err := s.Lists(bob, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(lists.Shared) != 1 || lists.Shared[0].ID != shared.ID ||
		lists.Shared[0].IsMine || lists.Shared[0].Owner.Username != "alice" {
		t.Fatalf("bob sees only alice's shared list, as hers: %+v", lists.Shared)
	}
}

// Un titre ajouté depuis le catalogue devient lisible le jour où le serveur
// reçoit sa fiche, sans rien réécrire.
func TestCatalogTitleAttachesToTheServerMediaOnceItArrives(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	item, err := s.AddCatalogTitle(alice, later.ID, CatalogTitle{
		MediaType: "tv", TMDBID: 1399, Title: "Game of Thrones", PosterPath: "/got.jpg", ReleaseDate: "2011-04-17",
	})
	if err != nil {
		t.Fatalf("AddCatalogTitle: %v", err)
	}
	if item.MediaID != 0 || item.MediaType != "show" || item.PosterURL != tmdbPosterBase+"/got.jpg" {
		t.Fatalf("catalog title before arrival: %+v", item)
	}
	if _, err := s.db.Exec(`INSERT INTO medias (id, type, title, tmdb_id) VALUES (20, 'show', 'GoT', 1399)`); err != nil {
		t.Fatal(err)
	}
	detail, err := s.Get(alice, later.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Items) != 1 || detail.Items[0].MediaID != 20 {
		t.Fatalf("title must attach to show 20: %+v", detail.Items)
	}
}

// Le même titre, depuis le catalogue puis depuis sa fiche, ne fait qu'un
// élément ; ajouter deux fois renvoie le premier.
func TestTheSameTitleIsNeverListedTwice(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	first, err := s.AddCatalogTitle(alice, later.ID, CatalogTitle{MediaType: "movie", TMDBID: 603, Title: "The Matrix"})
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.AddServerMedia(alice, later.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != first.ID {
		t.Fatalf("server media 10 is TMDB 603: got item %d, want %d", again.ID, first.ID)
	}
	plain, err := s.AddServerMedia(alice, later.ID, 11)
	if err != nil {
		t.Fatal(err)
	}
	if twice, err := s.AddServerMedia(alice, later.ID, 11); err != nil || twice.ID != plain.ID {
		t.Fatalf("media without TMDB added twice: %+v, %v", twice, err)
	}
	if got := watchLaterOf(t, s, alice).ItemCount; got != 2 {
		t.Fatalf("item count = %d, want 2", got)
	}
}

// Une liste partagée ne fait charger aux autres que des affiches TMDB : le
// serveur écrit l'adresse, l'app n'envoie qu'un chemin.
func TestCatalogTitleRefusesAnythingButATMDBPosterPath(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	for _, poster := range []string{
		"https://evil.example/p.jpg", "//evil.example/p.jpg", "/../etc/passwd", "/a.jpg?x=1", "abc.jpg",
	} {
		_, err := s.AddCatalogTitle(alice, later.ID, CatalogTitle{MediaType: "movie", TMDBID: 1, Title: "X", PosterPath: poster})
		if !errors.Is(err, ErrInvalid) {
			t.Errorf("poster %q: %v, want ErrInvalid", poster, err)
		}
	}
	for _, bad := range []CatalogTitle{
		{MediaType: "episode", TMDBID: 1, Title: "X"},
		{MediaType: "movie", TMDBID: 0, Title: "X"},
		{MediaType: "movie", TMDBID: 1, Title: "  "},
		{MediaType: "movie", TMDBID: 1, Title: "X", ReleaseDate: "demain"},
	} {
		if _, err := s.AddCatalogTitle(alice, later.ID, bad); !errors.Is(err, ErrInvalid) {
			t.Errorf("%+v: %v, want ErrInvalid", bad, err)
		}
	}
}

func TestOnlyMoviesAndShowsGoInAList(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	if _, err := s.AddServerMedia(alice, later.ID, 12); !errors.Is(err, ErrInvalid) {
		t.Fatalf("episode: %v, want ErrInvalid", err)
	}
	if _, err := s.AddServerMedia(alice, later.ID, 999); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing media: %v, want ErrInvalid", err)
	}
}

// La feuille « Ajouter à une liste » coche les listes qui ont déjà le titre,
// qu'on le demande par sa fiche ou par TMDB.
func TestProbeFindsTheTitleByMediaOrByTMDB(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	recos := mustCreate(t, s, alice, "Mes recos", false)
	item, err := s.AddServerMedia(alice, recos.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	for _, probe := range []Probe{{MediaID: 10}, {MediaType: "movie", TMDBID: 603}} {
		lists, err := s.Lists(alice, &probe)
		if err != nil {
			t.Fatal(err)
		}
		got := map[int]int{}
		for _, l := range lists.Mine {
			if l.ContainsItemID == nil {
				t.Fatalf("probe %+v: list %d has no answer", probe, l.ID)
			}
			got[l.ID] = *l.ContainsItemID
		}
		if got[recos.ID] != item.ID || got[later.ID] != 0 {
			t.Fatalf("probe %+v: %v", probe, got)
		}
	}
}

// Une fiche supprimée du serveur laisse son élément, sous l'instantané pris à
// l'ajout.
func TestRemovedMediaLeavesItsSnapshot(t *testing.T) {
	s := newTestStore(t)
	later := watchLaterOf(t, s, alice)
	if _, err := s.AddServerMedia(alice, later.ID, 11); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`DELETE FROM medias WHERE id = 11`); err != nil {
		t.Fatal(err)
	}
	detail, err := s.Get(alice, later.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Items) != 1 || detail.Items[0].MediaID != 0 || detail.Items[0].Title != "Vacances" {
		t.Fatalf("snapshot after removal: %+v", detail.Items)
	}
}

func TestListShowsItsCountAndLatestPosters(t *testing.T) {
	s := newTestStore(t)
	recos := mustCreate(t, s, alice, "Mes recos", true)
	for _, id := range []int{10, 11} {
		if _, err := s.AddServerMedia(alice, recos.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.AddCatalogTitle(alice, recos.ID, CatalogTitle{MediaType: "movie", TMDBID: 7, Title: "Sans affiche"}); err != nil {
		t.Fatal(err)
	}
	lists, err := s.Lists(bob, nil)
	if err != nil {
		t.Fatal(err)
	}
	got := lists.Shared[0]
	if got.ItemCount != 3 || len(got.Posters) != 2 || got.Posters[0] != "/posters/v.jpg" {
		t.Fatalf("count and posters, latest first: %+v", got)
	}
	if err := s.RemoveItem(alice, recos.ID, 999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("remove missing item: %v", err)
	}
}

func TestListNamesAreBounded(t *testing.T) {
	s := newTestStore(t)
	long := ""
	for i := 0; i <= MaxNameRunes; i++ {
		long += "é"
	}
	for _, name := range []string{"", "   ", long, "a\x00b"} {
		if _, err := s.Create(alice, ListParams{Name: name}); !errors.Is(err, ErrInvalid) {
			t.Errorf("name %q: %v, want ErrInvalid", name, err)
		}
	}
	l, err := s.Create(alice, ListParams{Name: "  Films   de Noël ", Description: " Pour décembre "})
	if err != nil || l.Name != "Films de Noël" || l.Description != "Pour décembre" {
		t.Fatalf("normalized list: %+v, %v", l, err)
	}
}
