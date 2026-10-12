package handlers

import (
	"net/http"
	"reflect"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"
)

// Attendre sa langue (ADR-0057) : ce que la rangée « À reprendre » montre
// d'une série qu'on suit en VF quand ses épisodes sortent d'abord en VO.

func TestJudgeLanguageWait(t *testing.T) {
	now := time.Date(2026, 10, 12, 20, 0, 0, 0, time.UTC)
	lastActivity := now.AddDate(0, 0, -10)
	old := now.AddDate(0, 0, -40)

	cases := []struct {
		name         string
		next         audioArrivals
		lastActivity time.Time
		want         languageWaitVerdict
	}{
		{
			name: "l'épisode n'existe qu'en japonais : la série attend",
			next: audioArrivals{"ja": old},
			want: languageWaitVerdict{stillWaiting: true},
		},
		{
			name: "la VF arrive sur un fichier présent depuis longtemps : nouveauté",
			next: audioArrivals{"ja": old, "fr": now.AddDate(0, 0, -2)},
			want: languageWaitVerdict{arrived: true},
		},
		{
			name: "la VF était déjà là la dernière fois qu'on s'est occupé de la série",
			next: audioArrivals{"fr": now.AddDate(0, 0, -12)},
			want: languageWaitVerdict{},
		},
		{
			name:         "la VF est arrivée il y a plus longtemps que la fenêtre de nouveauté",
			next:         audioArrivals{"fr": now.Add(-newEpisodeFreshness - time.Hour)},
			lastActivity: now.AddDate(0, 0, -60),
			want:         languageWaitVerdict{},
		},
		{
			name: "un épisode sans langue déclarée ne se cache pas",
			next: audioArrivals{"und": old},
			want: languageWaitVerdict{},
		},
		{
			name: "un épisode pas encore sondé ne se cache pas",
			next: nil,
			want: languageWaitVerdict{},
		},
	}
	for _, c := range cases {
		lastSeen := c.lastActivity
		if lastSeen.IsZero() {
			lastSeen = lastActivity
		}
		if got := judgeLanguageWait(c.next, "fr", lastSeen, now); got != c.want {
			t.Errorf("%s : %+v, attendu %+v", c.name, got, c.want)
		}
	}
}

func episodesOf(t *testing.T, showTitle string) []int {
	t.Helper()
	rows, err := database.DB.Query(
		`SELECT id FROM medias WHERE type = 'episode' AND title LIKE ? ORDER BY episode_number`,
		showTitle+" E%")
	if err != nil {
		t.Fatalf("list episodes of %q: %v", showTitle, err)
	}
	defer rows.Close()
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan episode id: %v", err)
		}
		ids = append(ids, id)
	}
	return ids
}

func seedAudioLang(t *testing.T, mediaID int, lang string, position int, seenAt time.Time) {
	t.Helper()
	if _, err := database.DB.Exec(`
		INSERT INTO media_audio_langs (media_id, lang, position, first_seen_at)
		VALUES (?, ?, ?, ?)`, mediaID, lang, position, sqliteStamp(seenAt)); err != nil {
		t.Fatalf("insert audio lang %s of media %d: %v", lang, mediaID, err)
	}
}

func awaitLanguage(t *testing.T, episodeID int, lang string) {
	t.Helper()
	if rec := putShowTrackPreferences(1, episodeID, `{"await_audio_lang":"`+lang+`"}`); rec.Code != http.StatusOK {
		t.Fatalf("await %q: status %d", lang, rec.Code)
	}
}

// seedDubbedAnime : quatre épisodes arrivés il y a longtemps en japonais, les
// trois premiers doublés et regardés, le quatrième encore en VO seulement.
func seedDubbedAnime(t *testing.T, title string, now time.Time) []int {
	t.Helper()
	arrivals := []time.Time{
		now.AddDate(0, 0, -60), now.AddDate(0, 0, -53),
		now.AddDate(0, 0, -46), now.AddDate(0, 0, -39),
	}
	insertShowWithArrivals(t, title, arrivals, now.AddDate(0, 0, -30))
	ids := episodesOf(t, title)
	for i, id := range ids {
		seedAudioLang(t, id, "ja", 0, arrivals[i])
		if i < 3 {
			seedAudioLang(t, id, "fr", 1, arrivals[i])
		}
	}
	return ids
}

func TestContinueWatchingFollowsTheAwaitedLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	now := time.Now().UTC()
	ids := seedDubbedAnime(t, "Anime", now)

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if findByShowTitle(items, "Anime") == nil {
		t.Fatal("sans attente, l'épisode en VO doit rester proposé")
	}

	awaitLanguage(t, ids[0], "fr")
	items, err = buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if got := findByShowTitle(items, "Anime"); got != nil {
		t.Fatalf("à jour dans sa langue, la série ne doit plus être proposée (épisode %q)", got.EpisodeTitle)
	}

	// La VF arrive sur l'épisode 4, dont le fichier a plus d'un mois.
	seedAudioLang(t, ids[3], "fr", 1, now.Add(time.Minute))
	items, err = buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	got := findByShowTitle(items, "Anime")
	if got == nil {
		t.Fatal("la série doit revenir dès que l'épisode existe dans la langue attendue")
	}
	if !got.HasNewEpisode {
		t.Fatal("l'arrivée de la langue attendue est une nouveauté, quel que soit l'âge du fichier")
	}
}

// Lancer une série qui n'existe qu'en VO, répondre « attendre », repartir :
// elle n'a aucune progression, et doit pourtant revenir le jour de sa VF.
func TestAwaitedShowNeverStartedComesBackWithItsLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	now := time.Now().UTC()
	seedShow(t, "Nouveau", 0, 0, 1, 2)
	ids := episodeIDs(t, "Nouveau")
	seedAudioLang(t, ids[0], "ja", 0, now.AddDate(0, 0, -30))
	awaitLanguage(t, ids[0], "fr")

	// Les quelques secondes passées devant la question n'entament pas l'épisode.
	if _, err := database.DB.Exec(`
		INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		VALUES (1, ?, 4, 0, ?)`, ids[0], sqliteStamp(now)); err != nil {
		t.Fatalf("insert progression: %v", err)
	}

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if got := findByShowTitle(items, "Nouveau"); got != nil {
		t.Fatal("une série qu'on attend dans sa langue ne se propose pas en VO")
	}

	seedAudioLang(t, ids[0], "fr", 1, now.Add(time.Minute))
	items, err = buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	got := findByShowTitle(items, "Nouveau")
	if got == nil || !got.HasNewEpisode {
		t.Fatalf("la série doit revenir comme une nouveauté avec sa langue : %+v", got)
	}
}

func TestAwaitedShowWithoutAnyProgressComesBackWithItsLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	now := time.Now().UTC()
	seedShow(t, "Vierge", 0, 0, 1)
	ids := episodeIDs(t, "Vierge")
	seedAudioLang(t, ids[0], "ja", 0, now.AddDate(0, 0, -30))
	awaitLanguage(t, ids[0], "fr")

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if findByShowTitle(items, "Vierge") != nil {
		t.Fatal("sans la langue attendue, la série reste hors de la rangée")
	}

	seedAudioLang(t, ids[0], "fr", 1, now.Add(time.Minute))
	items, err = buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if got := findByShowTitle(items, "Vierge"); got == nil || !got.HasNewEpisode {
		t.Fatalf("la série doit entrer dans la rangée avec sa langue : %+v", got)
	}
}

func TestContinueWatchingKeepsAnEpisodeStartedInAnotherLanguage(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	now := time.Now().UTC()
	ids := seedDubbedAnime(t, "Anime", now)
	awaitLanguage(t, ids[0], "fr")

	if _, err := database.DB.Exec(`
		INSERT INTO progressions (user_id, media_id, current_position_seconds, is_finished, updated_at)
		VALUES (1, ?, 600, 0, ?)`, ids[3], sqliteStamp(now)); err != nil {
		t.Fatalf("insert progression: %v", err)
	}

	items, err := buildShowContinueWatching(1, nil)
	if err != nil {
		t.Fatalf("buildShowContinueWatching: %v", err)
	}
	if findByShowTitle(items, "Anime") == nil {
		t.Fatal("un épisode entamé se reprend, même hors de la langue attendue")
	}
}

func TestChoosingAnotherAudioLanguageStopsTheWait(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	ids := seedDubbedAnime(t, "Anime", time.Now().UTC())

	awaitLanguage(t, ids[0], "fr")
	if rec := putShowTrackPreferences(1, ids[1], `{"audio_lang":"fr"}`); rec.Code != http.StatusOK {
		t.Fatalf("put: status %d", rec.Code)
	}
	if got := getShowTrackPreferences(t, 1, ids[2]); got.AwaitAudioLang != "fr" {
		t.Fatalf("choisir la langue attendue ne doit pas lever l'attente : %+v", got)
	}

	if rec := putShowTrackPreferences(1, ids[1], `{"audio_lang":"ja"}`); rec.Code != http.StatusOK {
		t.Fatalf("put: status %d", rec.Code)
	}
	if got := getShowTrackPreferences(t, 1, ids[2]); got.AwaitAudioLang != "" || got.AudioLang != "ja" {
		t.Fatalf("choisir une autre langue doit lever l'attente : %+v", got)
	}

	if rec := putShowTrackPreferences(1, ids[1], `{"await_audio_lang":"français"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("langue invalide : status %d, attendu 400", rec.Code)
	}
}

func TestEpisodeAudioLanguagesPutTheDefaultTrackFirst(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	now := time.Now().UTC()
	ids := seedDubbedAnime(t, "Anime", now)

	if got, want := episodeAudioLanguages(ids[0]), []string{"ja", "fr"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("langues de l'épisode 1 : %v, attendu %v", got, want)
	}

	var untagged int
	if err := database.DB.QueryRow(
		`SELECT id FROM medias WHERE type = ? AND title = 'Cinq cent enfants'`, models.TypeEpisode,
	).Scan(&untagged); err != nil {
		t.Fatalf("find fixture episode: %v", err)
	}
	seedAudioLang(t, untagged, "und", 0, now)
	if got := episodeAudioLanguages(untagged); len(got) != 0 {
		t.Fatalf("un fichier sans langue déclarée n'en annonce aucune : %v", got)
	}
}
