package handlers

import (
	"path/filepath"
	"strconv"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

// setupSeasonsTestDB builds a show with the given local seasons and returns the
// show id plus the season row ids, keyed by season number.
func setupSeasonsTestDB(t *testing.T, seasonNumbers ...int) (showID int, seasonIDs map[int]int) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	if _, err := database.InitDB(dbPath); err != nil {
		t.Fatalf("InitDB: %v", err)
	}

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title) VALUES (?, ?)", models.TypeShow, "Lioness",
	)
	if err != nil {
		t.Fatalf("insert show: %v", err)
	}
	id, _ := res.LastInsertId()
	showID = int(id)

	seasonIDs = map[int]int{}
	for _, number := range seasonNumbers {
		res, err := database.DB.Exec(
			"INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, ?, ?, ?)",
			models.TypeSeason, "Saison "+strconv.Itoa(number), showID, number,
		)
		if err != nil {
			t.Fatalf("insert season %d: %v", number, err)
		}
		seasonID, _ := res.LastInsertId()
		seasonIDs[number] = int(seasonID)
	}
	return showID, seasonIDs
}

func TestResolveFollowingSeasonPicksNextLocalSeason(t *testing.T) {
	showID, seasonIDs := setupSeasonsTestDB(t, 1, 2, 3)

	number, localID := resolveFollowingSeason(showID, 1)

	if number != 2 {
		t.Fatalf("expected season 2 to follow season 1, got %d", number)
	}
	if localID != seasonIDs[2] {
		t.Fatalf("expected local season id %d, got %d", seasonIDs[2], localID)
	}
}

// With a gap in the library and TMDB unavailable (no API key in tests), the
// server cannot know season 2 exists, so it falls back to the next season it
// actually holds. When TMDB does answer, season 2 wins instead and comes back
// with localSeasonID 0, which is what turns into the request card.
func TestResolveFollowingSeasonFallsBackToNextHeldSeasonWithoutTMDB(t *testing.T) {
	showID, seasonIDs := setupSeasonsTestDB(t, 1, 3)

	number, localID := resolveFollowingSeason(showID, 1)

	if number != 3 {
		t.Fatalf("expected season 3, got %d", number)
	}
	if localID != seasonIDs[3] {
		t.Fatalf("expected local season id %d, got %d", seasonIDs[3], localID)
	}
}

func TestResolveFollowingSeasonReturnsZeroAfterLastSeason(t *testing.T) {
	showID, _ := setupSeasonsTestDB(t, 1, 2)

	number, localID := resolveFollowingSeason(showID, 2)

	if number != 0 || localID != 0 {
		t.Fatalf("expected nothing after the last season, got number=%d id=%d", number, localID)
	}
}

// A weekly show: the server holds episodes 1 to 4 of a ten-episode season, so
// what follows episode 4 is episode 5 — not the season after, which is what
// used to be offered for request three episodes too early.
func TestNextTMDBEpisodeAfterPicksTheEpisodeStillToCome(t *testing.T) {
	episodes := []TMDBEpisodeSummary{
		{Number: 1}, {Number: 2}, {Number: 3}, {Number: 4},
		{Number: 5, Name: "Descent", AirDate: "2026-09-05"},
		{Number: 6},
	}

	next := nextTMDBEpisodeAfter(episodes, 4)

	if next == nil {
		t.Fatal("expected episode 5 to follow episode 4")
	}
	if next.Number != 5 || next.Name != "Descent" {
		t.Fatalf("expected episode 5 \"Descent\", got %d %q", next.Number, next.Name)
	}
}

// TMDB does not guarantee the episode list is ordered, and picking the first
// match rather than the lowest would skip straight past the next episode.
func TestNextTMDBEpisodeAfterIgnoresListOrder(t *testing.T) {
	episodes := []TMDBEpisodeSummary{{Number: 8}, {Number: 5}, {Number: 6}}

	next := nextTMDBEpisodeAfter(episodes, 4)

	if next == nil {
		t.Fatal("expected episode 5 from an unordered list")
	}
	if next.Number != 5 {
		t.Fatalf("expected episode 5, got %d", next.Number)
	}
}

// The season really is over: nothing to report, which is what hands the screen
// back to the end-of-season request card.
func TestNextTMDBEpisodeAfterReturnsNilOnTheLastEpisode(t *testing.T) {
	episodes := []TMDBEpisodeSummary{{Number: 1}, {Number: 2}, {Number: 3}}

	if next := nextTMDBEpisodeAfter(episodes, 3); next != nil {
		t.Fatalf("expected nothing after the last episode, got %d", next.Number)
	}
}

// An episode whose number never got parsed says nothing about its position in
// the season; episode 1 would otherwise read as "upcoming" for every one.
func TestDescribeUpcomingEpisodeIgnoresUnnumberedEpisodes(t *testing.T) {
	showID, _ := setupSeasonsTestDB(t, 1)

	if upcoming := describeUpcomingEpisode(showID, 1, 0); upcoming != nil {
		t.Fatalf("expected no upcoming episode for an unnumbered one, got %+v", upcoming)
	}
}
