package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/medialang"
	"project-player/server/models"
)

func getMoviesIn(t *testing.T, acceptLanguage string) []models.HomeMediaItem {
	t.Helper()
	r := httptest.NewRequest("GET", "/api/movies", nil)
	if acceptLanguage != "" {
		r.Header.Set("Accept-Language", acceptLanguage)
	}
	w := httptest.NewRecorder()
	GetMovies(w, r, nil, 1)
	if w.Code != 200 {
		t.Fatalf("GetMovies status = %d, body %s", w.Code, w.Body.String())
	}
	var movies []models.HomeMediaItem
	if err := json.Unmarshal(w.Body.Bytes(), &movies); err != nil {
		t.Fatalf("decode movies: %v", err)
	}
	return movies
}

func seedTranslatedMovie(t *testing.T) {
	t.Helper()
	res, err := database.DB.Exec(`
		INSERT INTO medias (type, title, overview, tmdb_id, file_path)
		VALUES ('movie', 'Le Parrain', 'Une famille de la mafia.', 238, 'Le.Parrain.mkv')`)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	id, _ := res.LastInsertId()
	if err := medialang.Save(int(id), "en", 238, medialang.Text{
		Title: "The Godfather", Overview: "A crime family.",
	}); err != nil {
		t.Fatal(err)
	}

	// Un film dont TMDB n'a pas de synopsis anglais : la ligne existe, vide.
	res, err = database.DB.Exec(`
		INSERT INTO medias (type, title, overview, tmdb_id, file_path)
		VALUES ('movie', 'Un film rare', 'Synopsis français.', 77, 'Rare.mkv')`)
	if err != nil {
		t.Fatalf("insert movie: %v", err)
	}
	id, _ = res.LastInsertId()
	if err := medialang.Save(int(id), "en", 77, medialang.Text{Title: "A Rare Film"}); err != nil {
		t.Fatal(err)
	}
}

func movieTitled(movies []models.HomeMediaItem, title string) *models.HomeMediaItem {
	for i := range movies {
		if movies[i].Title == title {
			return &movies[i]
		}
	}
	return nil
}

// La bibliothèque répond dans la langue que l'app annonce (ADR-0049).
func TestLibraryIsServedInTheLanguageTheAppAnnounces(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedTranslatedMovie(t)

	english := getMoviesIn(t, "en")
	godfather := movieTitled(english, "The Godfather")
	if godfather == nil {
		t.Fatalf("no English title in %+v", english)
	}
	if godfather.Overview != "A crime family." {
		t.Errorf("overview = %q, want the English one", godfather.Overview)
	}
}

// Une app d'avant ce réglage n'annonce rien : elle reçoit ce qu'elle recevait.
func TestLibraryWithoutALanguageStaysInTheBaseLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedTranslatedMovie(t)

	for _, header := range []string{"", "fr", "de"} {
		if movieTitled(getMoviesIn(t, header), "Le Parrain") == nil {
			t.Errorf("Accept-Language %q did not get the base title", header)
		}
	}
}

// Un texte que TMDB n'a pas dans la langue demandée laisse celui de base :
// un synopsis français vaut mieux qu'une fiche vide.
func TestMissingTranslatedFieldFallsBackToTheBaseText(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	seedTranslatedMovie(t)

	rare := movieTitled(getMoviesIn(t, "en"), "A Rare Film")
	if rare == nil {
		t.Fatal("translated title missing")
	}
	if rare.Overview != "Synopsis français." {
		t.Errorf("overview = %q, want the base overview kept", rare.Overview)
	}
}

// Un épisode porte le titre de sa série : il suit la même langue, sans que le
// numéro d'épisode, lu dans le titre de base, s'en trouve changé.
func TestEpisodeCarriesItsShowTitleInTheSameLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()

	exec := func(query string, args ...interface{}) int {
		t.Helper()
		res, err := database.DB.Exec(query, args...)
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
		id, _ := res.LastInsertId()
		return int(id)
	}
	show := exec(`INSERT INTO medias (type, title, tmdb_id) VALUES ('show', 'La Casa de Papel', 71446)`)
	season := exec(`INSERT INTO medias (type, title, parent_id, season_number) VALUES ('season', 'Saison 1', ?, 1)`, show)
	episode := exec(`
		INSERT INTO medias (type, title, parent_id, season_number, episode_number, file_path)
		VALUES ('episode', 'Épisode 1', ?, 1, 1, 'S01E01.mkv')`, season)
	for id, text := range map[int]medialang.Text{
		show:    {Title: "Money Heist"},
		episode: {Title: "Episode 1", Overview: "The heist begins."},
	} {
		if err := medialang.Save(id, "en", 71446, text); err != nil {
			t.Fatal(err)
		}
	}

	r := httptest.NewRequest("GET", "/api/seasons/1/episodes", nil)
	r.Header.Set("Accept-Language", "en-GB,en;q=0.8")
	item, ok := findEpisodeInSeason(1, season, 0)
	if !ok {
		t.Fatal("episode not found")
	}
	languageOf(r).items(&item)

	if item.Title != "Episode 1" || item.Overview != "The heist begins." {
		t.Errorf("episode = %q / %q", item.Title, item.Overview)
	}
	if item.ShowTitle != "Money Heist" {
		t.Errorf("show title = %q, want Money Heist", item.ShowTitle)
	}
	if item.EpisodeNumber != 1 || item.SeasonNumber != 1 {
		t.Errorf("numbers = S%dE%d, want S1E1", item.SeasonNumber, item.EpisodeNumber)
	}
}
