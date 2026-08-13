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
