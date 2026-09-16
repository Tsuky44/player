package handlers

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

// seedMovies inserts n identified films, each with two file versions, oldest
// first so that created_at ordering is unambiguous.
func seedMovies(t *testing.T, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		for _, quality := range []string{"1080p", "2160p"} {
			_, err := database.DB.Exec(`
				INSERT INTO medias (type, title, tmdb_id, file_path, poster_url, duration, created_at)
				VALUES ('movie', ?, ?, ?, '/p.jpg', 7200, datetime('2020-01-01', '+' || ? || ' days'))`,
				fmt.Sprintf("Film %02d", i), 1000+i,
				fmt.Sprintf("Film.%02d.%s.mkv", i, quality), i,
			)
			if err != nil {
				t.Fatalf("insert movie %d: %v", i, err)
			}
		}
	}
}

func decodeHome(t *testing.T) models.HomeResponse {
	t.Helper()
	w := httptest.NewRecorder()
	Home(w, httptest.NewRequest("GET", "/api/home", nil), nil, 1)
	if w.Code != 200 {
		t.Fatalf("Home status = %d, body %s", w.Code, w.Body.String())
	}
	var resp models.HomeResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode home: %v", err)
	}
	return resp
}

// TestHomeRecentMoviesAreCardsNewestFirst pins the ordering the bounded query
// has to reproduce: the rows are now picked by a subquery on the grouping key,
// so a card must still land where its newest file put it.
func TestHomeRecentMoviesAreCardsNewestFirst(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedMovies(t, 40)

	resp := decodeHome(t)

	if len(resp.RecentMovies) != homeRecentMovies {
		t.Fatalf("RecentMovies = %d cards, want %d", len(resp.RecentMovies), homeRecentMovies)
	}
	// Film 39 is the newest, and the row is newest-first.
	for i, card := range resp.RecentMovies {
		want := fmt.Sprintf("Film %02d", 39-i)
		if card.Title != want {
			t.Fatalf("RecentMovies[%d] = %q, want %q", i, card.Title, want)
		}
	}
}

// TestHomeCollapsesVersionsIntoOneCard is the reason the limit cannot simply be
// a LIMIT on the outer query: two files of one film are one card, so fifteen
// cards need thirty rows.
func TestHomeCollapsesVersionsIntoOneCard(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedMovies(t, 20)

	resp := decodeHome(t)

	for i, card := range resp.RecentMovies {
		if len(card.Versions) != 2 {
			t.Fatalf("RecentMovies[%d] (%s) has %d versions, want 2", i, card.Title, len(card.Versions))
		}
	}
	titles := map[string]bool{}
	for _, card := range resp.RecentMovies {
		if titles[card.Title] {
			t.Fatalf("film %q appears on two cards", card.Title)
		}
		titles[card.Title] = true
	}
}

// TestHomeKeepsUnidentifiedMoviesApart guards the negated-id half of the
// grouping key: films without a tmdb_id must not collapse into each other.
func TestHomeKeepsUnidentifiedMoviesApart(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	for i := 0; i < 5; i++ {
		_, err := database.DB.Exec(`
			INSERT INTO medias (type, title, tmdb_id, file_path, poster_url, duration)
			VALUES ('movie', ?, 0, ?, '/p.jpg', 7200)`,
			fmt.Sprintf("Inconnu %d", i), fmt.Sprintf("Inconnu.%d.mkv", i))
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
	}

	resp := decodeHome(t)

	if len(resp.RecentMovies) != 5 {
		t.Fatalf("RecentMovies = %d, want 5 separate cards", len(resp.RecentMovies))
	}
	for _, card := range resp.RecentMovies {
		if len(card.Versions) != 0 {
			t.Fatalf("%q grouped with another film: %+v", card.Title, card.Versions)
		}
	}
}

// TestHomeDiscoveryIsBoundedAndGrouped covers the random row, whose ordering is
// deliberately not asserted.
func TestHomeDiscoveryIsBoundedAndGrouped(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedMovies(t, 60)

	resp := decodeHome(t)

	if len(resp.DiscoveryMovies) != homeDiscoveryItems {
		t.Fatalf("DiscoveryMovies = %d, want %d", len(resp.DiscoveryMovies), homeDiscoveryItems)
	}
	seen := map[int]bool{}
	for _, card := range resp.DiscoveryMovies {
		if seen[card.TMDBID] {
			t.Fatalf("film %d appears twice in discovery", card.TMDBID)
		}
		seen[card.TMDBID] = true
		if len(card.Versions) != 2 {
			t.Fatalf("%q has %d versions, want 2", card.Title, len(card.Versions))
		}
	}
}

// TestHomeDiscoverySkipsArtworkless keeps the poster filter that the card-key
// subquery now has to repeat.
func TestHomeDiscoverySkipsArtworkless(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedMovies(t, 3)
	if _, err := database.DB.Exec(`
		INSERT INTO medias (type, title, tmdb_id, file_path, poster_url, duration)
		VALUES ('movie', 'Sans affiche', 9999, 'Sans.affiche.mkv', '', 7200)`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	resp := decodeHome(t)

	for _, card := range resp.DiscoveryMovies {
		if card.Title == "Sans affiche" {
			t.Fatal("a film without artwork reached the discovery row")
		}
	}
	if len(resp.RecentMovies) != 4 {
		t.Fatalf("RecentMovies = %d, want 4 (the recent row has no artwork filter)", len(resp.RecentMovies))
	}
}
