package artwork

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func TestPostersInTheInterfaceLanguageComeFirst(t *testing.T) {
	images := []models.RemoteImage{
		{URL: "de", Language: "de", Votes: 50},
		{URL: "en", Language: "en", Votes: 40},
		{URL: "textless", Language: "", Votes: 1},
		{URL: "fr-few", Language: "fr", Votes: 2},
		{URL: "fr-many", Language: "fr", Votes: 9},
		{URL: "fr-rated", Language: "fr", Votes: 2, Rating: 6.1},
	}
	rank(images, "fr")
	var got []string
	for _, img := range images {
		got = append(got, img.URL)
	}
	want := "fr-many fr-rated fr-few textless en de"
	if strings.Join(got, " ") != want {
		t.Fatalf("ordre = %v, attendu %s", got, want)
	}
}

func TestTMDBPostersAreStoredAtTheIndexerSize(t *testing.T) {
	images, err := parseTMDBPosters(strings.NewReader(`{"posters":[
		{"file_path":"/a.jpg","iso_639_1":"fr","vote_average":5.4,"vote_count":3,"width":2000,"height":3000},
		{"file_path":"/b.jpg","iso_639_1":null},
		{"file_path":""}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(images) != 2 {
		t.Fatalf("%d affiches, attendu 2 (le chemin vide est écarté)", len(images))
	}
	if images[0].URL != "https://image.tmdb.org/t/p/w500/a.jpg" ||
		images[0].ThumbURL != "https://image.tmdb.org/t/p/w185/a.jpg" ||
		images[0].Language != "fr" || images[0].Votes != 3 || images[0].Source != "tmdb" {
		t.Fatalf("affiche TMDB mal lue : %+v", images[0])
	}
	if images[1].Language != "" {
		t.Fatalf("une affiche sans langue doit rester sans langue : %+v", images[1])
	}
}

func TestFanartPostersAreHTTPSWithAPreview(t *testing.T) {
	images, err := parseFanartPosters(strings.NewReader(`{"movieposter":[
		{"url":"http://assets.fanart.tv/fanart/movies/1/movieposter/x.jpg","lang":"00","likes":"7"},
		{"url":"https://assets.fanart.tv/fanart/movies/1/movieposter/y.jpg","lang":"fr","likes":"?"},
		{"url":"ftp://elsewhere/z.jpg","lang":"en","likes":"1"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(images) != 2 {
		t.Fatalf("%d affiches, attendu 2 (une adresse non http est écartée)", len(images))
	}
	first := images[0]
	if first.URL != "https://assets.fanart.tv/fanart/movies/1/movieposter/x.jpg" ||
		first.ThumbURL != "https://assets.fanart.tv/preview/movies/1/movieposter/x.jpg" ||
		first.Language != "" || first.Votes != 7 || first.Source != "fanart" {
		t.Fatalf("affiche Fanart.tv mal lue : %+v", first)
	}
	if images[1].Votes != 0 {
		t.Fatalf("un compteur illisible vaut zéro : %+v", images[1])
	}
	for _, img := range images {
		if !Allowed(img.URL) {
			t.Fatalf("une affiche proposée doit pouvoir être choisie : %s", img.URL)
		}
	}
}

func TestOnlyPosterSitesCanBeStored(t *testing.T) {
	cases := map[string]bool{
		"https://image.tmdb.org/t/p/w500/a.jpg":          true,
		"https://assets.fanart.tv/fanart/movies/1/a.jpg": true,
		"http://image.tmdb.org/t/p/w500/a.jpg":           false,
		"https://evil.example/a.jpg":                     false,
		"https://image.tmdb.org.evil.example/a.jpg":      false,
		"https://user@image.tmdb.org/a.jpg":              false,
		"javascript:alert(1)":                            false,
		"":                                               false,
	}
	for raw, want := range cases {
		if got := Allowed(raw); got != want {
			t.Errorf("Allowed(%q) = %v, attendu %v", raw, got, want)
		}
	}
}

func openTestDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("init db: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
}

func insertMedia(t *testing.T, mediaType string, parent *int, poster string) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO medias (type, title, parent_id, poster_url, tmdb_id) VALUES (?, ?, ?, ?, 0)`,
		mediaType, mediaType, parent, poster)
	if err != nil {
		t.Fatalf("insert %s: %v", mediaType, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("insert %s: %v", mediaType, err)
	}
	return int(id)
}

func posterOf(t *testing.T, id int) (string, bool) {
	t.Helper()
	var poster string
	var locked bool
	if err := database.DB.QueryRow(
		`SELECT COALESCE(poster_url, ''), poster_locked FROM medias WHERE id = ?`, id,
	).Scan(&poster, &locked); err != nil {
		t.Fatalf("read %d: %v", id, err)
	}
	return poster, locked
}

func TestAChosenShowPosterIsLockedAndFollowedByItsEpisodes(t *testing.T) {
	openTestDB(t)
	const old = "https://image.tmdb.org/t/p/w500/old.jpg"
	const chosen = "https://assets.fanart.tv/fanart/tv/1/tvposter/new.jpg"
	show := insertMedia(t, "show", nil, old)
	season := insertMedia(t, "season", &show, old)
	inherited := insertMedia(t, "episode", &season, old)
	still := insertMedia(t, "episode", &season, "https://image.tmdb.org/t/p/w500/still.jpg")
	other := insertMedia(t, "show", nil, old)

	if err := Choose(show, chosen); err != nil {
		t.Fatalf("Choose: %v", err)
	}
	if poster, locked := posterOf(t, show); poster != chosen || !locked {
		t.Fatalf("série : %q verrouillée=%v, attendu %q verrouillée", poster, locked, chosen)
	}
	for _, id := range []int{season, inherited} {
		if poster, _ := posterOf(t, id); poster != chosen {
			t.Errorf("%d portait l'affiche de la série et ne l'a pas suivie : %q", id, poster)
		}
	}
	if poster, _ := posterOf(t, still); !strings.HasSuffix(poster, "still.jpg") {
		t.Errorf("un épisode avec sa propre image ne doit pas la perdre : %q", poster)
	}
	if poster, _ := posterOf(t, other); poster != old {
		t.Errorf("une autre série a changé d'affiche : %q", poster)
	}
}

func TestChooseRefusesUnknownHostsAndEpisodes(t *testing.T) {
	openTestDB(t)
	movie := insertMedia(t, "movie", nil, "")
	if err := Choose(movie, "https://evil.example/a.jpg"); !errors.Is(err, ErrHostNotAllowed) {
		t.Fatalf("hôte inconnu : err = %v", err)
	}
	if poster, locked := posterOf(t, movie); poster != "" || locked {
		t.Fatalf("un refus ne doit rien écrire : %q verrouillée=%v", poster, locked)
	}
	season := insertMedia(t, "season", &movie, "")
	if err := Choose(season, "https://image.tmdb.org/t/p/w500/a.jpg"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("une saison n'a pas d'affiche à elle : err = %v", err)
	}
}

func TestResetWithoutTMDBUnlocksTheChosenPoster(t *testing.T) {
	openTestDB(t)
	movie := insertMedia(t, "movie", nil, "")
	const chosen = "https://image.tmdb.org/t/p/w500/a.jpg"
	if err := Choose(movie, chosen); err != nil {
		t.Fatalf("Choose: %v", err)
	}
	if err := Reset(movie); err != nil {
		t.Fatalf("Reset: %v", err)
	}
	poster, locked := posterOf(t, movie)
	if locked {
		t.Fatal("la marque doit tomber, pour que le prochain rattrapage remette l'affiche par défaut")
	}
	if poster != chosen {
		t.Fatalf("sans TMDB, l'affiche reste en place jusqu'au rattrapage : %q", poster)
	}
}
