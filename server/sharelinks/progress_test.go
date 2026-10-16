package sharelinks

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// insertMedia ajoute un film lisible id, pour qu'un lien ait plusieurs médias
// à suivre.
func insertMedia(t *testing.T, s *Store, id int) {
	t.Helper()
	if _, err := s.db.Exec(`INSERT INTO medias (id, type, title, file_path, duration) VALUES (?, 'movie', 'Autre', '/autre.mkv', 3000)`, id); err != nil {
		t.Fatalf("insert media %d: %v", id, err)
	}
}

func shareIDOf(t *testing.T, s *Store, code string) int {
	t.Helper()
	share, err := s.Find(code)
	if err != nil {
		t.Fatalf("Find: %v", err)
	}
	return share.ID
}

func progressRows(t *testing.T, s *Store) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM media_share_progress`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestNormalizeViewerName_IgnoresCaseAndExtraSpaces(t *testing.T) {
	name, key, err := NormalizeViewerName("  Marie   Claire ")
	if err != nil || name != "Marie Claire" || key != "marie claire" {
		t.Fatalf("got %q %q %v", name, key, err)
	}
	for _, bad := range []string{"", "   ", strings.Repeat("a", MaxViewerNameRunes+1), "Ma\x00rie"} {
		if _, _, err := NormalizeViewerName(bad); !errors.Is(err, ErrViewerName) {
			t.Errorf("NormalizeViewerName(%q) = %v, want ErrViewerName", bad, err)
		}
	}
	if _, _, err := NormalizeViewerName(strings.Repeat("é", MaxViewerNameRunes)); err != nil {
		t.Errorf("a name of %d accented letters is refused: %v", MaxViewerNameRunes, err)
	}
}

func TestProgress_IsKeptPerViewerNameWhateverTheCase(t *testing.T) {
	s, _ := newTestStore(t)
	shareID := shareIDOf(t, s, mustCreate(t, s, CreateParams{}))

	if err := s.SaveProgress(shareID, "Marie", 7, 1200, false); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveProgress(shareID, "Paul", 7, 300, false); err != nil {
		t.Fatal(err)
	}

	marie, err := s.Progress(shareID, "  marie ")
	if err != nil {
		t.Fatal(err)
	}
	if marie.Name != "Marie" || marie.Positions[7] != 1200 || marie.LastMediaID != 7 {
		t.Fatalf("marie = %+v", marie)
	}
	paul, _ := s.Progress(shareID, "PAUL")
	if paul.Positions[7] != 300 {
		t.Fatalf("paul = %+v", paul)
	}
	unknown, err := s.Progress(shareID, "Zoé")
	if err != nil || len(unknown.Positions) != 0 || unknown.LastMediaID != 0 || unknown.Name != "Zoé" {
		t.Fatalf("unknown viewer = %+v, %v", unknown, err)
	}
}

func TestProgress_FinishedMediaLosesItsPositionAndLastIsTheMostRecent(t *testing.T) {
	s, now := newTestStore(t)
	insertMedia(t, s, 8)
	shareID := shareIDOf(t, s, mustCreate(t, s, CreateParams{}))

	if err := s.SaveProgress(shareID, "Marie", 7, 2950, true); err != nil {
		t.Fatal(err)
	}
	// Dans la même seconde : l'épisode suivant démarre pendant que l'ancien
	// lecteur envoie sa dernière position. Les millisecondes gardent l'ordre.
	*now = now.Add(5 * time.Millisecond)
	if err := s.SaveProgress(shareID, "Marie", 8, 40, false); err != nil {
		t.Fatal(err)
	}

	got, err := s.Progress(shareID, "Marie")
	if err != nil {
		t.Fatal(err)
	}
	if _, has := got.Positions[7]; has || len(got.Finished) != 1 || got.Finished[0] != 7 {
		t.Fatalf("finished media kept a position: %+v", got)
	}
	if got.Positions[8] != 40 || got.LastMediaID != 8 {
		t.Fatalf("progress = %+v, want media 8 at 40s and last", got)
	}

	// Relancé, un média vu redevient « en cours ».
	*now = now.Add(time.Second)
	if err := s.SaveProgress(shareID, "Marie", 7, 60, false); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Progress(shareID, "Marie")
	if len(got.Finished) != 0 || got.Positions[7] != 60 || got.LastMediaID != 7 {
		t.Fatalf("rewatched media = %+v", got)
	}
}

func TestProgress_DeletingTheLinkDeletesItsProgress(t *testing.T) {
	s, _ := newTestStore(t)
	shareID := shareIDOf(t, s, mustCreate(t, s, CreateParams{}))
	if err := s.SaveProgress(shareID, "Marie", 7, 1200, false); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(shareID, 1); err != nil {
		t.Fatal(err)
	}
	if n := progressRows(t, s); n != 0 {
		t.Fatalf("%d progress rows outlived their deleted link", n)
	}
}

func TestPurgeEndedProgress_RemovesOnlyLinksThatNoLongerOpen(t *testing.T) {
	s, now := newTestStore(t)
	expiring := shareIDOf(t, s, mustCreate(t, s, CreateParams{LifetimeHours: 24}))
	permanent := shareIDOf(t, s, mustCreate(t, s, CreateParams{}))
	watched := shareIDOf(t, s, mustCreate(t, s, CreateParams{SingleUse: true}))
	for _, id := range []int{expiring, permanent, watched} {
		if err := s.SaveProgress(id, "Marie", 7, 1200, false); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Consume(watched); err != nil {
		t.Fatal(err)
	}

	if n, err := s.PurgeEndedProgress(); err != nil || n != 0 {
		t.Fatalf("purge of live links: %d, %v", n, err)
	}

	*now = now.Add(25 * time.Hour)
	if n, err := s.PurgeEndedProgress(); err != nil || n != 2 {
		t.Fatalf("purge after expiry: %d rows, %v; want the expired and the watched link", n, err)
	}
	if got, _ := s.Progress(permanent, "Marie"); got.Positions[7] != 1200 {
		t.Fatalf("progress of a live link purged: %+v", got)
	}
}

func TestSaveProgress_RefusesANewViewerPastTheLimit(t *testing.T) {
	s, _ := newTestStore(t)
	shareID := shareIDOf(t, s, mustCreate(t, s, CreateParams{}))
	for i := 0; i < MaxViewersPerShare; i++ {
		if err := s.SaveProgress(shareID, fmt.Sprintf("Viewer %d", i), 7, 10, false); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SaveProgress(shareID, "Encore un", 7, 10, false); !errors.Is(err, ErrTooManyViewers) {
		t.Fatalf("new viewer past the limit: %v, want ErrTooManyViewers", err)
	}
	if err := s.SaveProgress(shareID, "viewer 3", 7, 20, false); err != nil {
		t.Fatalf("a known viewer is refused past the limit: %v", err)
	}
}
