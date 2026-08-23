package handlers

import (
	"fmt"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

var newEpisodeNow = time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)

func daysAgo(d int) time.Time {
	return newEpisodeNow.AddDate(0, 0, -d)
}

func dateOf(t time.Time) string {
	return t.Format("2006-01-02")
}

// episodeArrival builds the two fields the new-episode test reads: when the
// file landed on the server, and when TMDB says it aired.
func episodeArrival(id int, arrived time.Time, airDate string) episodeProgressRow {
	var row episodeProgressRow
	row.item.ID = id
	row.item.CreatedAt = arrived
	row.item.ReleaseDate = airDate
	return row
}

// weeklyShow is the case the badge exists for: one episode a week, each landing
// on the server the day it airs.
func weeklyShow() []episodeProgressRow {
	var eps []episodeProgressRow
	for i, d := range []int{28, 21, 14, 7, 1} {
		eps = append(eps, episodeArrival(100+i, daysAgo(d), dateOf(daysAgo(d))))
	}
	return eps
}

func TestIsNewEpisodeRelease_WeeklyDrop(t *testing.T) {
	eps := weeklyShow()
	if !isNewEpisodeRelease(eps, &eps[len(eps)-1], newEpisodeNow) {
		t.Fatal("latest weekly episode should be flagged as new")
	}
}

func TestIsNewEpisodeRelease_ViewerIsBehind(t *testing.T) {
	eps := weeklyShow()
	// Resume target is two episodes back: a newer one exists, but it is not the
	// one waiting for the viewer, so the card must stay plain.
	if isNewEpisodeRelease(eps, &eps[len(eps)-3], newEpisodeNow) {
		t.Fatal("episode the viewer has not reached yet should not be flagged")
	}
}

func TestIsNewEpisodeRelease_SeasonImportedInOneBatch(t *testing.T) {
	var eps []episodeProgressRow
	arrived := daysAgo(2)
	for i := 0; i < 8; i++ {
		// Aired weekly last spring, all downloaded in one go two days ago.
		eps = append(eps, episodeArrival(200+i, arrived, dateOf(daysAgo(9+7*(7-i)))))
	}
	if isNewEpisodeRelease(eps, &eps[len(eps)-1], newEpisodeNow) {
		t.Fatal("season that landed as a single batch should not be flagged")
	}
}

func TestIsNewEpisodeRelease_SameDayArrival(t *testing.T) {
	eps := weeklyShow()
	last := len(eps) - 1
	// The finale shows up a few hours after the previous episode — still one
	// drop, not a weekly release.
	eps[last].item.CreatedAt = eps[last-1].item.CreatedAt.Add(5 * time.Hour)
	eps[last].item.ReleaseDate = dateOf(eps[last].item.CreatedAt)
	if isNewEpisodeRelease(eps, &eps[last], newEpisodeNow) {
		t.Fatal("episode arriving the same day as the previous one should not be flagged")
	}
}

func TestIsNewEpisodeRelease_OldSeasonAddedToday(t *testing.T) {
	// Season 1 has been on the server for months; season 2, which aired five
	// years ago, is added today as a single episode so far.
	eps := []episodeProgressRow{
		episodeArrival(300, daysAgo(200), dateOf(daysAgo(2000))),
		episodeArrival(301, daysAgo(200), dateOf(daysAgo(1993))),
		episodeArrival(302, daysAgo(1), dateOf(daysAgo(1800))),
	}
	if isNewEpisodeRelease(eps, &eps[2], newEpisodeNow) {
		t.Fatal("back-catalogue episode should not be flagged as new")
	}
}

func TestIsNewEpisodeRelease_StaleArrival(t *testing.T) {
	eps := []episodeProgressRow{
		episodeArrival(400, daysAgo(70), dateOf(daysAgo(70))),
		episodeArrival(401, daysAgo(60), dateOf(daysAgo(60))),
	}
	if isNewEpisodeRelease(eps, &eps[1], newEpisodeNow) {
		t.Fatal("episode that arrived two months ago should no longer be flagged")
	}
}

func TestIsNewEpisodeRelease_LateDownloadWithinMargin(t *testing.T) {
	// The server picked the episode up five days after it aired — the margin
	// the air-date check exists for.
	eps := weeklyShow()
	last := len(eps) - 1
	eps[last].item.CreatedAt = daysAgo(1)
	eps[last].item.ReleaseDate = dateOf(daysAgo(6))
	if !isNewEpisodeRelease(eps, &eps[last], newEpisodeNow) {
		t.Fatal("episode downloaded a few days after airing should still be flagged")
	}
}

func TestIsNewEpisodeRelease_FirstEpisodeNeedsAirDate(t *testing.T) {
	withAir := []episodeProgressRow{episodeArrival(500, daysAgo(1), dateOf(daysAgo(1)))}
	if !isNewEpisodeRelease(withAir, &withAir[0], newEpisodeNow) {
		t.Fatal("fresh premiere with a matching air date should be flagged")
	}

	withoutAir := []episodeProgressRow{episodeArrival(501, daysAgo(1), "")}
	if isNewEpisodeRelease(withoutAir, &withoutAir[0], newEpisodeNow) {
		t.Fatal("lone episode with no air date has nothing to vouch for it")
	}
}

func TestIsNewEpisodeRelease_UnknownArrival(t *testing.T) {
	eps := weeklyShow()
	last := len(eps) - 1
	eps[last].item.CreatedAt = time.Time{}
	if isNewEpisodeRelease(eps, &eps[last], newEpisodeNow) {
		t.Fatal("episode with no arrival date should not be flagged")
	}
}

// --- End to end: the flag as it comes out of SQLite ---------------------------

func sqliteStamp(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04:05")
}

// insertShowWithArrivals builds a show whose episodes landed on the server at
// the given times, every one of them aired the day it arrived. All but the last
// episode are marked as watched, so the last one is the resume target.
func insertShowWithArrivals(t *testing.T, title string, arrivals []time.Time, watchedAt time.Time) {
	t.Helper()

	res, err := database.DB.Exec(
		"INSERT INTO medias (type, title, poster_url) VALUES (?, ?, ?)",
		models.TypeShow, title, "/show.jpg",
	)
	if err != nil {
		t.Fatalf("insert show %s: %v", title, err)
	}
	showID, _ := res.LastInsertId()

	res, err = database.DB.Exec(
		"INSERT INTO medias (type, title, parent_id, season_number) VALUES (?, ?, ?, ?)",
		models.TypeSeason, "Saison 1", showID, 1,
	)
	if err != nil {
		t.Fatalf("insert season %s: %v", title, err)
	}
	seasonID, _ := res.LastInsertId()

	for i, arrived := range arrivals {
		res, err = database.DB.Exec(
			`INSERT INTO medias
			   (type, title, file_path, duration, parent_id, season_number, episode_number,
			    release_date, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			models.TypeEpisode, fmt.Sprintf("%s E%d", title, i+1),
			fmt.Sprintf("/%s-%d.mkv", title, i+1), 2400, seasonID, 1, i+1,
			arrived.UTC().Format("2006-01-02"), sqliteStamp(arrived),
		)
		if err != nil {
			t.Fatalf("insert episode %d of %s: %v", i+1, title, err)
		}
		if i == len(arrivals)-1 {
			continue // the resume target stays unwatched
		}
		epID, _ := res.LastInsertId()
		_, err = database.DB.Exec(
			`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
			 VALUES (1, ?, 2400, 1, ?)`,
			epID, sqliteStamp(watchedAt),
		)
		if err != nil {
			t.Fatalf("insert progression for %s: %v", title, err)
		}
	}
}

func findByShowTitle(items []models.HomeMediaItem, title string) *models.HomeMediaItem {
	for i := range items {
		if items[i].ShowTitle == title {
			return &items[i]
		}
	}
	return nil
}

func TestBuildShowContinueWatching_FlagsWeeklyRelease(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	now := time.Now().UTC()
	weekly := []time.Time{
		now.AddDate(0, 0, -22), now.AddDate(0, 0, -15),
		now.AddDate(0, 0, -8), now.AddDate(0, 0, -1),
	}
	insertShowWithArrivals(t, "Hebdo", weekly, now.AddDate(0, 0, -6))

	batch := []time.Time{
		now.AddDate(0, 0, -3), now.AddDate(0, 0, -3),
		now.AddDate(0, 0, -3), now.AddDate(0, 0, -3),
	}
	insertShowWithArrivals(t, "Coffret", batch, now.AddDate(0, 0, -2))

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}

	hebdo := findByShowTitle(items, "Hebdo")
	if hebdo == nil {
		t.Fatal("weekly show missing from continue watching")
	}
	if !hebdo.HasNewEpisode {
		t.Fatalf("weekly show should carry HasNewEpisode (episode %q)", hebdo.EpisodeTitle)
	}

	coffret := findByShowTitle(items, "Coffret")
	if coffret == nil {
		t.Fatal("batch-imported show missing from continue watching")
	}
	if coffret.HasNewEpisode {
		t.Fatal("show imported in one batch should not carry HasNewEpisode")
	}
}

func TestBuildContinueWatching_NewEpisodeSortsFirst(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	now := time.Now().UTC()
	// Watched a week ago — without the new episode this show would sit behind
	// the movie the user paused an hour ago.
	insertShowWithArrivals(t, "Hebdo", []time.Time{
		now.AddDate(0, 0, -15), now.AddDate(0, 0, -8), now.AddDate(0, 0, -1),
	}, now.AddDate(0, 0, -7))

	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, file_path, duration) VALUES (?, ?, ?, ?)`,
		models.TypeMovie, "Film récent", "/film.mkv", 6000,
	)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	movieID, _ := res.LastInsertId()
	_, err = database.DB.Exec(
		`INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		 VALUES (1, ?, 3000, 0, ?)`,
		movieID, sqliteStamp(now.Add(-time.Hour)),
	)
	if err != nil {
		t.Fatalf("insert movie progression: %v", err)
	}

	items, err := buildContinueWatching(1, 10)
	if err != nil {
		t.Fatalf("buildContinueWatching: %v", err)
	}
	if len(items) < 2 {
		t.Fatalf("expected the movie and the show, got %d item(s)", len(items))
	}
	if items[0].ShowTitle != "Hebdo" {
		t.Fatalf("first item = %q, want the show with a new episode", items[0].Title)
	}
}
