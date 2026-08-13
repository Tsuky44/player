package subtitles

import (
	"path/filepath"
	"testing"

	"project-player/server/database"
	"project-player/server/streaming"
)

// setupCatalogTestDB opens a throwaway database and inserts the media rows the
// subtitles table's foreign key requires.
func setupCatalogTestDB(t *testing.T, mediaIDs ...int) {
	t.Helper()
	db, err := database.InitDB(filepath.Join(t.TempDir(), "catalog_test.db"))
	if err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	for _, id := range mediaIDs {
		if _, err := database.DB.Exec(
			`INSERT INTO medias (id, type, title, file_path) VALUES (?, 'movie', ?, ?)`,
			id, "Fixture", "/media/fixture.mkv",
		); err != nil {
			t.Fatalf("insert media %d: %v", id, err)
		}
	}
}

// Catalog is what pairs a Direct Play embedded track with its canonical entry:
// the client maps mpv's subtitle id to a typed index and looks it up here. If
// the index is lost, that pairing silently falls back to nothing and a subtitle
// chosen in Direct Play disappears on the switch to HLS.
func TestCatalog_StampsTypedIndexOnBothPaths(t *testing.T) {
	setupCatalogTestDB(t, 101)
	const mediaID = 101

	// Only the German track has been extracted so far.
	if err := Register(mediaID, "de", "Deutsch", "/subs/m101.de.vtt", false); err != nil {
		t.Fatalf("register: %v", err)
	}

	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("fre", 0, false), // not extracted yet -> ready=false
		sub("spa", 1, true),  // bitmap -> listed, but in its own key namespace
		sub("ger", 2, false), // extracted -> ready=true, merged from the DB
	}}

	got := Catalog(mediaID, probe)
	if len(got) != 3 {
		t.Fatalf("expected 3 tracks (bitmap included), got %d (%+v)", len(got), got)
	}

	fr, spa, de := got[0], got[1], got[2]
	if fr.Lang != "fr" || de.Lang != "de" {
		t.Fatalf("unexpected languages: %q, %q", fr.Lang, de.Lang)
	}
	// The bitmap track must NOT consume a text key: doing so would rename every
	// text track after it and break the pairing with the .vtt files on disk.
	if !spa.Image {
		t.Errorf("bitmap track not flagged: %+v", spa)
	}
	if spa.Lang != "img1" {
		t.Errorf("bitmap key = %q, want img1 (separate namespace)", spa.Lang)
	}
	if !spa.Ready {
		t.Error("a bitmap track needs no extraction, so it is usable right away")
	}

	// The pending track carries its index straight from the probe...
	if fr.Ready {
		t.Error("fr should still be pending")
	}
	if fr.TypedIndex != 0 {
		t.Errorf("fr typed index = %d, want 0", fr.TypedIndex)
	}

	// ...and the DB-merged one must be stamped too, even though the row itself
	// knows nothing about stream positions.
	if !de.Ready {
		t.Error("de should be ready")
	}
	if de.TypedIndex != 2 {
		t.Errorf("de typed index = %d, want 2 (the bitmap stream still occupies 0:s:1)",
			de.TypedIndex)
	}
}

// The whole point of the separate namespace: a bitmap track sitting between two
// French tracks must not shift the second one from "fr2" to something else, or
// the key would no longer name the .vtt that planTextSubtitles wrote.
func TestCatalog_BitmapTrackDoesNotShiftTextKeys(t *testing.T) {
	setupCatalogTestDB(t, 505)

	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("fra", 0, false),
		sub("fra", 1, true), // bitmap French wedged in the middle
		sub("fra", 2, false),
	}}

	got := Catalog(505, probe)
	if len(got) != 3 {
		t.Fatalf("expected 3 tracks, got %d", len(got))
	}
	if got[0].Lang != "fr" {
		t.Errorf("first text track = %q, want fr", got[0].Lang)
	}
	if got[2].Lang != "fr2" {
		t.Errorf("second text track = %q, want fr2 — the bitmap track stole a key",
			got[2].Lang)
	}

	// And the planner must agree, since it names the files.
	planned := planTextSubtitles(505, probe, "/subs")
	if len(planned) != 2 {
		t.Fatalf("planner should skip the bitmap track, got %d", len(planned))
	}
	if planned[0].key != got[0].Lang || planned[1].key != got[2].Lang {
		t.Errorf("planner keys %q/%q disagree with catalog keys %q/%q",
			planned[0].key, planned[1].key, got[0].Lang, got[2].Lang)
	}
}

func TestCatalog_PartialSurvivesTheMerge(t *testing.T) {
	setupCatalogTestDB(t, 202)
	const mediaID = 202

	if err := Register(mediaID, "fr", "Francais", "/subs/m202.fr.vtt", true); err != nil {
		t.Fatalf("register: %v", err)
	}

	probe := &streaming.ProbeResult{Subtitles: []streaming.SubtitleStreamInfo{
		sub("fra", 0, false),
	}}

	got := Catalog(mediaID, probe)
	if len(got) != 1 {
		t.Fatalf("expected 1 track, got %d", len(got))
	}
	if !got[0].Ready {
		t.Error("a head-extracted track is usable, so it must report ready")
	}
	if !got[0].Partial {
		t.Error("partial flag lost — the client would never re-attach the full version")
	}
	if got[0].TypedIndex != 0 {
		t.Errorf("typed index = %d, want 0", got[0].TypedIndex)
	}
}

// A file carrying both a full and a forced track for one language is the case
// that makes the flag matter: the keys are assigned in container order, so
// without `forced` the client cannot tell which of "fr"/"fr2" is the near-empty
// one and may hand the user foreign-dialogue-only cues labelled "Français".
func TestCatalog_ExposesForcedAndDefault(t *testing.T) {
	setupCatalogTestDB(t, 404)
	const mediaID = 404

	forcedFirst := streaming.SubtitleStreamInfo{
		TypedIndex: 0, Language: "fra", Codec: "subrip", Forced: true,
	}
	fullSecond := streaming.SubtitleStreamInfo{
		TypedIndex: 1, Language: "fra", Codec: "subrip", Default: true,
	}
	probe := &streaming.ProbeResult{
		Subtitles: []streaming.SubtitleStreamInfo{forcedFirst, fullSecond},
	}

	got := Catalog(mediaID, probe)
	if len(got) != 2 {
		t.Fatalf("expected 2 tracks, got %d", len(got))
	}

	if got[0].Lang != "fr" || !got[0].Forced {
		t.Errorf("first track should be the forced one: %+v", got[0])
	}
	if got[0].Default {
		t.Errorf("first track is not the container default: %+v", got[0])
	}
	if got[1].Lang != "fr2" || got[1].Forced {
		t.Errorf("second track should be the full one: %+v", got[1])
	}
	if !got[1].Default {
		t.Errorf("second track is flagged default in the container: %+v", got[1])
	}
}

// Without a probe (no tracks_json yet) the catalog degrades to whatever is in
// the DB, and must say so rather than inventing a stream position.
func TestCatalog_NoProbeReportsUnknownIndex(t *testing.T) {
	setupCatalogTestDB(t, 303)
	const mediaID = 303

	if err := Register(mediaID, "en", "English", "/subs/m303.en.vtt", false); err != nil {
		t.Fatalf("register: %v", err)
	}

	got := Catalog(mediaID, nil)
	if len(got) != 1 {
		t.Fatalf("expected 1 track, got %d", len(got))
	}
	if got[0].TypedIndex != -1 {
		t.Errorf("typed index = %d, want -1 (unknown)", got[0].TypedIndex)
	}
}
