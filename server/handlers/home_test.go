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

// seedShow inserts a series whose show row, and whose episodes, were indexed on
// the given days (as offsets from 2020-01-01). An empty episodeDays leaves the
// series without a single file.
func seedShow(t *testing.T, title string, tmdbID, showDay int, episodeDays ...int) {
	t.Helper()
	res, err := database.DB.Exec(`
		INSERT INTO medias (type, title, tmdb_id, poster_url, created_at)
		VALUES ('show', ?, ?, '/p.jpg', datetime('2020-01-01', '+' || ? || ' days'))`,
		title, tmdbID, showDay)
	if err != nil {
		t.Fatalf("insert show %q: %v", title, err)
	}
	showID, _ := res.LastInsertId()

	res, err = database.DB.Exec(`
		INSERT INTO medias (type, title, parent_id, season_number, created_at)
		VALUES ('season', 'Saison 1', ?, 1, datetime('2020-01-01', '+' || ? || ' days'))`,
		showID, showDay)
	if err != nil {
		t.Fatalf("insert season of %q: %v", title, err)
	}
	seasonID, _ := res.LastInsertId()

	for i, day := range episodeDays {
		_, err = database.DB.Exec(`
			INSERT INTO medias (type, title, file_path, duration, parent_id, season_number, episode_number, created_at)
			VALUES ('episode', ?, ?, 2400, ?, 1, ?, datetime('2020-01-01', '+' || ? || ' days'))`,
			fmt.Sprintf("%s S01E%02d", title, i+1),
			fmt.Sprintf("%s.S01E%02d.mkv", title, i+1),
			seasonID, i+1, day)
		if err != nil {
			t.Fatalf("insert episode of %q: %v", title, err)
		}
	}
}

func showTitles(shows []models.Media) []string {
	titles := make([]string, 0, len(shows))
	for _, s := range shows {
		titles = append(titles, s.Title)
	}
	return titles
}

// TestHomeRecentShowsFollowNewFiles is the row's whole point: a series that was
// added long ago but just received episodes is news, and the show row's own
// created_at cannot say so.
func TestHomeRecentShowsFollowNewFiles(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	// Lioness comes from the fixture, with an episode indexed "now"; the days
	// below stay in 2020 so it cannot jump between the series under test.
	seedShow(t, "Ancienne avec saison neuve", 2001, 10, 11, 12, 900)
	seedShow(t, "Ajoutee recemment", 2002, 800, 801)
	seedShow(t, "Ancienne et figee", 2003, 20, 21)

	resp := decodeHome(t)

	got := showTitles(resp.RecentShows)
	want := []string{"Lioness", "Ancienne avec saison neuve", "Ajoutee recemment", "Ancienne et figee"}
	if len(got) != len(want) {
		t.Fatalf("RecentShows = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("RecentShows = %v, want %v", got, want)
		}
	}
}

// TestHomeRecentShowsOrderIsStable guards the display dedupe, which used to
// iterate a Go map and hand the home screen a different order on every load.
func TestHomeRecentShowsOrderIsStable(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	for i := 0; i < 12; i++ {
		seedShow(t, fmt.Sprintf("Serie %02d", i), 3000+i, i, i)
	}

	first := showTitles(decodeHome(t).RecentShows)
	for attempt := 0; attempt < 5; attempt++ {
		got := showTitles(decodeHome(t).RecentShows)
		for i := range first {
			if got[i] != first[i] {
				t.Fatalf("RecentShows reordered between requests: %v then %v", first, got)
			}
		}
	}
	// Newest first, the fixture's Lioness ahead of every 2020 series.
	want := []string{"Lioness", "Serie 11", "Serie 10", "Serie 09"}
	for i, title := range want {
		if first[i] != title {
			t.Fatalf("RecentShows = %v, want it to start with %v", first, want)
		}
	}
}

// TestHomeRecentShowsKeepSeriesWithoutEpisodes covers the floor of the
// ordering: a show row with no file falls back to its own created_at instead of
// dropping out of the row.
func TestHomeRecentShowsKeepSeriesWithoutEpisodes(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedShow(t, "Sans episode", 4001, 500)
	seedShow(t, "Avec episodes", 4002, 100, 101)

	got := showTitles(decodeHome(t).RecentShows)
	want := []string{"Lioness", "Sans episode", "Avec episodes"}
	if len(got) != len(want) {
		t.Fatalf("RecentShows = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("RecentShows = %v, want %v", got, want)
		}
	}
}
