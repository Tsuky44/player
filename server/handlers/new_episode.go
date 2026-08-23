package handlers

import (
	"time"
)

// A weekly series drops one episode at a time: the file lands on the server
// days after the previous one, on or around its TMDB air date. A season that
// was imported in one go — whether it aired last month or ten years ago —
// lands as a single batch. These three windows separate the two cases.
const (
	// How long an episode keeps its "new" flag after landing on the server.
	// Wide enough that someone who opens the app once a week still sees it.
	newEpisodeFreshness = 21 * 24 * time.Hour

	// Episodes that arrived closer together than this belong to the same
	// import batch — a season dropped at once, not a weekly release.
	newEpisodeBatchGap = 24 * time.Hour

	// TMDB air dates and the moment a file actually shows up on the server
	// rarely match to the day, so they only have to agree within this margin.
	// Past it, the episode is a back-catalogue import, not a fresh release.
	newEpisodeAirMargin = 14 * 24 * time.Hour
)

// parseAirDate reads the TMDB air date stored on an episode ("2026-08-12").
func parseAirDate(raw string) (time.Time, bool) {
	if len(raw) < 10 {
		return time.Time{}, false
	}
	t, err := time.Parse("2006-01-02", raw[:10])
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// indexOfEpisode locates a resume row inside the show's ordered episode list.
func indexOfEpisode(episodes []episodeProgressRow, row *episodeProgressRow) int {
	if row == nil {
		return -1
	}
	for i := range episodes {
		if episodes[i].item.ID == row.item.ID {
			return i
		}
	}
	return -1
}

// latestArrivalBefore returns the most recent arrival among the episodes that
// come before idx. Comparing against the whole head of the list rather than the
// single previous episode keeps the batch test honest when files land out of
// order (a backfilled gap, a re-downloaded episode).
func latestArrivalBefore(episodes []episodeProgressRow, idx int) time.Time {
	var latest time.Time
	for i := 0; i < idx && i < len(episodes); i++ {
		at := episodes[i].item.CreatedAt
		if at.IsZero() {
			continue
		}
		if latest.IsZero() || at.After(latest) {
			latest = at
		}
	}
	return latest
}

// isNewEpisodeRelease reports whether the episode the user is about to resume
// is a freshly released one — the weekly drop they have not watched yet.
//
// Three conditions, matching what "new episode" means to a viewer:
//
//  1. It is the last episode the show has. If the user is several episodes
//     behind, the one waiting for them is not the new one, and the badge would
//     say nothing they don't already know.
//  2. It landed on the server recently, and later than everything before it.
//     A season imported in a single batch fails this: its episodes all share
//     one arrival time.
//  3. Its TMDB air date is close to that arrival. This is what separates a
//     genuine premiere or weekly episode from an old season added to the
//     library today — the latter aired years before it arrived.
func isNewEpisodeRelease(episodes []episodeProgressRow, row *episodeProgressRow, now time.Time) bool {
	idx := indexOfEpisode(episodes, row)
	if idx < 0 || idx != len(episodes)-1 {
		return false
	}

	arrived := episodes[idx].item.CreatedAt
	if arrived.IsZero() || now.Sub(arrived) > newEpisodeFreshness {
		return false
	}

	air, hasAir := parseAirDate(episodes[idx].item.ReleaseDate)
	if hasAir {
		// Aired long before it arrived: back catalogue, not a new release.
		if arrived.Sub(air) > newEpisodeAirMargin {
			return false
		}
		// Not yet aired (placeholder metadata, wrong episode match).
		if air.Sub(arrived) > newEpisodeAirMargin {
			return false
		}
	}

	previous := latestArrivalBefore(episodes, idx)
	if previous.IsZero() {
		// Nothing to compare against — the show's very first episode, or an
		// index with no arrival dates. Only the air date can vouch for it.
		return hasAir
	}
	return arrived.Sub(previous) > newEpisodeBatchGap
}
