package medialang

import (
	"path/filepath"
	"testing"

	"project-player/server/database"
)

// Sans réglage enregistré ni variable d'environnement, la langue de base est
// le français : c'est l'hypothèse de tout ce fichier.
func TestFromHeaderKeepsOnlyInterfaceLanguages(t *testing.T) {
	t.Setenv("TMDB_LANGUAGE", "")

	cases := []struct {
		header string
		want   string
	}{
		{"en", "en"},
		{"en-US,en;q=0.9,fr;q=0.8", "en"},
		{"EN_gb", "en"},
		{"fr", "fr"},
		{"fr-CA, en;q=0.5", "fr"},
		// Une langue que l'interface n'a pas, ou pas d'en-tête : la base.
		{"de-DE,de;q=0.9", "fr"},
		// La première langue connue l'emporte, même derrière une inconnue.
		{"de-DE,en;q=0.8", "en"},
		{"", "fr"},
		{"*", "fr"},
	}
	for _, c := range cases {
		if got := FromHeader(c.header); got != c.want {
			t.Errorf("FromHeader(%q) = %q, want %q", c.header, got, c.want)
		}
	}
}

func TestBaseLanguageKeepsItsConfiguredLocale(t *testing.T) {
	t.Setenv("TMDB_LANGUAGE", "fr-CA")

	if got := TMDBLocale("fr"); got != "fr-CA" {
		t.Errorf("TMDBLocale(fr) = %q, want the configured fr-CA", got)
	}
	if got := TMDBLocale("en"); got != "en-US" {
		t.Errorf("TMDBLocale(en) = %q, want en-US", got)
	}
	if got := Secondary(); len(got) != 1 || got[0] != "en" {
		t.Errorf("Secondary() = %v, want [en]", got)
	}
}

func TestSecondaryFollowsTheBaseLanguage(t *testing.T) {
	t.Setenv("TMDB_LANGUAGE", "en-US")
	if got := Secondary(); len(got) != 1 || got[0] != "fr" {
		t.Errorf("Secondary() = %v, want [fr]", got)
	}

	// Une base hors des langues de l'interface : il faut les garder toutes.
	t.Setenv("TMDB_LANGUAGE", "de-DE")
	if got := Secondary(); len(got) != 2 {
		t.Errorf("Secondary() = %v, want fr and en", got)
	}
}

func setupDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
}

func insertMedia(t *testing.T, query string, args ...interface{}) int {
	t.Helper()
	res, err := database.DB.Exec(query, args...)
	if err != nil {
		t.Fatalf("insert media: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

// Une fiche ré-identifiée ne doit pas garder le synopsis du film qu'elle
// n'est plus : la traduction tirée de l'ancienne identité est ignorée.
func TestTextsIgnoresATranslationFromAnotherIdentity(t *testing.T) {
	setupDB(t)

	kept := insertMedia(t, `INSERT INTO medias (type, title, tmdb_id) VALUES ('movie', 'Le Parrain', 238)`)
	rematched := insertMedia(t, `INSERT INTO medias (type, title, tmdb_id) VALUES ('movie', 'Alien', 348)`)
	if err := Save(kept, "en", 238, Text{Title: "The Godfather", Overview: "A crime family."}); err != nil {
		t.Fatal(err)
	}
	if err := Save(rematched, "en", 999, Text{Title: "Some Other Film"}); err != nil {
		t.Fatal(err)
	}

	texts, err := Texts("en", []int{kept, rematched})
	if err != nil {
		t.Fatal(err)
	}
	if got := texts[kept].Title; got != "The Godfather" {
		t.Errorf("kept title = %q, want The Godfather", got)
	}
	if _, ok := texts[rematched]; ok {
		t.Errorf("a translation from tmdb 999 was served for a media now on tmdb 348")
	}
}

// La traduction d'un épisode dépend de l'identité de sa série, qu'il pende à
// une saison ou directement à la série.
func TestTextsTiesAnEpisodeToItsShow(t *testing.T) {
	setupDB(t)

	show := insertMedia(t, `INSERT INTO medias (type, title, tmdb_id) VALUES ('show', 'Série', 1399)`)
	season := insertMedia(t, `INSERT INTO medias (type, title, parent_id) VALUES ('season', 'Saison 1', ?)`, show)
	inSeason := insertMedia(t, `INSERT INTO medias (type, title, parent_id) VALUES ('episode', 'L''hiver vient', ?)`, season)
	onShow := insertMedia(t, `INSERT INTO medias (type, title, parent_id) VALUES ('episode', 'La route royale', ?)`, show)
	stale := insertMedia(t, `INSERT INTO medias (type, title, parent_id) VALUES ('episode', 'Lord Snow', ?)`, season)

	for id, text := range map[int]Text{
		inSeason: {Title: "Winter Is Coming"},
		onShow:   {Title: "The Kingsroad"},
	} {
		if err := Save(id, "en", 1399, text); err != nil {
			t.Fatal(err)
		}
	}
	if err := Save(stale, "en", 4242, Text{Title: "From another show"}); err != nil {
		t.Fatal(err)
	}

	texts, err := Texts("en", []int{inSeason, onShow, stale})
	if err != nil {
		t.Fatal(err)
	}
	if texts[inSeason].Title != "Winter Is Coming" || texts[onShow].Title != "The Kingsroad" {
		t.Errorf("episode translations = %+v", texts)
	}
	if _, ok := texts[stale]; ok {
		t.Errorf("an episode translation from another show was served")
	}
}

// Changer la langue des métadonnées laissait medias dans l'ancienne langue
// jusqu'à une ré-identification complète, alors que les textes de la nouvelle
// étaient déjà en base : ils s'échangent.
func TestRebaseSwapsBaseTextsWithTheirTranslation(t *testing.T) {
	setupDB(t)

	movie := insertMedia(t, `INSERT INTO medias (type, title, overview, tmdb_id) VALUES ('movie', 'Le Parrain', 'Une famille.', 238)`)
	untranslated := insertMedia(t, `INSERT INTO medias (type, title, overview, tmdb_id) VALUES ('movie', 'Film maison', 'Rien sur TMDB.', 7)`)
	noOverview := insertMedia(t, `INSERT INTO medias (type, title, overview, tmdb_id) VALUES ('movie', 'Les Évadés', 'Une prison.', 278)`)
	if err := Save(movie, "en", 238, Text{Title: "The Godfather", Overview: "A crime family."}); err != nil {
		t.Fatal(err)
	}
	if err := Save(noOverview, "en", 278, Text{Title: "The Shawshank Redemption"}); err != nil {
		t.Fatal(err)
	}

	if err := Rebase("fr", "en"); err != nil {
		t.Fatal(err)
	}

	readBase := func(id int) Text {
		var text Text
		if err := database.DB.QueryRow(`SELECT title, COALESCE(overview, '') FROM medias WHERE id = ?`, id).
			Scan(&text.Title, &text.Overview); err != nil {
			t.Fatal(err)
		}
		return text
	}
	if got := readBase(movie); got.Title != "The Godfather" || got.Overview != "A crime family." {
		t.Errorf("base text after rebase = %+v", got)
	}
	if got := readBase(untranslated); got.Title != "Film maison" {
		t.Errorf("a media without translation lost its text: %+v", got)
	}
	if got := readBase(noOverview); got.Title != "The Shawshank Redemption" || got.Overview != "Une prison." {
		t.Errorf("an untranslated overview must stay readable: %+v", got)
	}

	// La langue de base est lue dans l'environnement : la passer en anglais
	// pour relire les textes français comme des traductions.
	t.Setenv("TMDB_LANGUAGE", "en-US")
	french, err := Texts("fr", []int{movie, untranslated})
	if err != nil {
		t.Fatal(err)
	}
	if got := french[movie]; got.Title != "Le Parrain" || got.Overview != "Une famille." {
		t.Errorf("the old base text was not kept as a translation: %+v", got)
	}
	if _, ok := french[untranslated]; ok {
		t.Errorf("a media that kept its text does not need a translation of it")
	}
	if english, _ := Texts("en", []int{movie}); len(english) != 0 {
		t.Errorf("translations in the new base language must be gone, got %+v", english)
	}
}

func TestSeasonLabelFollowsTheLanguage(t *testing.T) {
	if got := SeasonLabel("en", 2); got != "Season 2" {
		t.Errorf("SeasonLabel(en) = %q", got)
	}
	for _, code := range []string{"fr", "de"} {
		if got := SeasonLabel(code, 2); got != "Saison 2" {
			t.Errorf("SeasonLabel(%s) = %q", code, got)
		}
	}
}
