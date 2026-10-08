package indexer

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"project-player/server/database"
	"project-player/server/httpx"
	"project-player/server/medialang"
	"project-player/server/models"
	"project-player/server/safego"
	"project-player/server/tmdb"
)

// Les titres et synopsis dans les langues de l'interface que la table medias
// ne porte pas (ADR-0049). Tout ce fichier est idempotent : il ne demande à
// TMDB que ce qui manque, ou ce dont la fiche a changé d'identité depuis.

// translationPause espace les appels à TMDB, comme le reste de l'enrichissement.
const translationPause = 120 * time.Millisecond

var (
	translating atomic.Bool
	// translationRequested : une demande est arrivée depuis que le passage en
	// cours a lu sa file. Il repassera, pour la fiche qu'il n'a pas pu voir.
	translationRequested atomic.Bool
)

// translationSettled est, en SQL, ce qui fait qu'une ligne `t` de
// media_translations règle la question pour la fiche `m`. Une ligne incomplète
// (TMDB n'avait pas le titre ou le synopsis) est redemandée au plus une fois
// par jour pendant les soixante jours qui suivent l'arrivée de la fiche : un
// épisode importé le jour de sa diffusion n'a souvent qu'un « Episode 5 » sans
// synopsis, que TMDB complète dans les semaines suivantes. Passé ce délai, un
// vide veut dire que TMDB n'aura rien, et la ligne ne coûte plus d'appel.
const translationSettled = `NOT (
		(t.title = '' OR t.overview = '')
		AND t.fetched_at < datetime('now', '-1 day')
		AND t.fetched_at < COALESCE(datetime(m.created_at, '+60 days'), ''))`

// TranslateMissingAsync complète les traductions en arrière-plan. Si un
// passage tourne déjà, il repassera une fois fini : la fiche qui vient de
// changer d'identité n'était pas dans la file qu'il a lue.
func TranslateMissingAsync() {
	go safego.Run("translateMissing", func() { translateMissing() })
}

func translateMissing() {
	if tmdbAPIKey() == "" {
		return
	}
	translationRequested.Store(true)
	for translationRequested.Load() && translating.CompareAndSwap(false, true) {
		translationRequested.Store(false)
		translatePass()
		translating.Store(false)
	}
}

func translatePass() {
	for _, language := range medialang.Secondary() {
		titles := translateTitles(language)
		episodes := translateEpisodes(language)
		if titles+episodes > 0 {
			log.Printf("TMDB: %d fiches et %d épisodes traduits (%s)", titles, episodes, language)
		}
	}
}

// tmdbGet décode une réponse TMDB. found distingue « TMDB n'a pas cette
// fiche » (404, définitif) d'un échec de passage, qu'il faudra retenter.
func tmdbGet(u string, out interface{}) (found bool, err error) {
	resp, err := tmdb.Get(httpx.Standard, u)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return true, json.NewDecoder(resp.Body).Decode(out)
	case http.StatusNotFound:
		return false, nil
	default:
		return false, fmt.Errorf("status %d", resp.StatusCode)
	}
}

type titleToTranslate struct {
	id        int
	mediaType models.MediaType
	tmdbID    int
}

func loadTitlesToTranslate(language string) ([]titleToTranslate, error) {
	rows, err := database.DB.Query(`
		SELECT m.id, m.type, m.tmdb_id
		FROM medias m
		WHERE m.type IN ('movie', 'show') AND COALESCE(m.tmdb_id, 0) > 0
		  AND NOT EXISTS (
		    SELECT 1 FROM media_translations t
		    WHERE t.media_id = m.id AND t.language = ? AND t.source_tmdb_id = m.tmdb_id
		      AND `+translationSettled+`)
		ORDER BY m.type, m.tmdb_id`, language)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var queue []titleToTranslate
	for rows.Next() {
		var it titleToTranslate
		if err := rows.Scan(&it.id, &it.mediaType, &it.tmdbID); err != nil {
			return nil, err
		}
		queue = append(queue, it)
	}
	return queue, rows.Err()
}

// fetchTitleTranslation lit le titre et le synopsis d'un film ou d'une série
// dans une langue. Un titre que TMDB n'a pas traduit revient sous son titre
// original : c'est ce qu'un lecteur de cette langue s'attend à lire.
func fetchTitleTranslation(tmdbID int, mediaType models.MediaType, language string) (medialang.Text, error) {
	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}
	var details tmdbDetails
	found, err := tmdbGet(fmt.Sprintf(
		"/%s/%d?language=%s",
		endpoint, tmdbID, medialang.TMDBLocale(language),
	), &details)
	if err != nil {
		return medialang.Text{}, err
	}
	if !found {
		return medialang.Text{}, nil
	}
	return medialang.Text{
		Title:    strings.TrimSpace(tmdbDisplayTitle(details.Title, details.Name, mediaType)),
		Overview: strings.TrimSpace(details.Overview),
	}, nil
}

func translateTitles(language string) int {
	queue, err := loadTitlesToTranslate(language)
	if err != nil {
		log.Printf("TMDB: translations: title queue (%s): %v", language, err)
		return 0
	}
	if len(queue) > 0 {
		// Le premier passage d'une bibliothèque demande une fiche à la fois :
		// le dire, pour qu'un enrichissement qui dure ne passe pas pour figé.
		log.Printf("TMDB: translations: %d fiches à traduire (%s)…", len(queue), language)
	}

	// Les versions d'un même film partagent une identité : une seule requête.
	type key struct {
		mediaType models.MediaType
		tmdbID    int
	}
	fetched := map[key]medialang.Text{}
	saved := 0
	for _, it := range queue {
		k := key{it.mediaType, it.tmdbID}
		text, ok := fetched[k]
		if !ok {
			text, err = fetchTitleTranslation(it.tmdbID, it.mediaType, language)
			time.Sleep(translationPause)
			if err != nil {
				log.Printf("TMDB: translations: %s %d (%s): %v", it.mediaType, it.tmdbID, language, err)
				continue
			}
			fetched[k] = text
		}
		if err := medialang.Save(it.id, language, it.tmdbID, text); err != nil {
			log.Printf("TMDB: translations: %v", err)
			continue
		}
		saved++
	}
	return saved
}

type episodeToTranslate struct {
	id         int
	showTMDBID int
	seasonNum  int
	episodeNum int
}

func loadEpisodesToTranslate(language string) ([]episodeToTranslate, error) {
	rows, err := database.DB.Query(`
		SELECT m.id, m.title, COALESCE(m.file_path, ''),
		       COALESCE(m.season_number, 0), COALESCE(m.episode_number, 0),
		       COALESCE(src_parent.title, ''), `+medialang.SourceTMDBID+`
		FROM medias m`+medialang.SourceJoins+`
		WHERE m.type = 'episode' AND `+medialang.SourceTMDBID+` > 0
		  AND NOT EXISTS (
		    SELECT 1 FROM media_translations t
		    WHERE t.media_id = m.id AND t.language = ?
		      AND t.source_tmdb_id = `+medialang.SourceTMDBID+`
		      AND `+translationSettled+`)
		ORDER BY 7, m.id`, language)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var queue []episodeToTranslate
	for rows.Next() {
		var it episodeToTranslate
		var title, filePath, parentTitle string
		var storedSeason, storedEpisode int
		if err := rows.Scan(&it.id, &title, &filePath, &storedSeason, &storedEpisode,
			&parentTitle, &it.showTMDBID); err != nil {
			return nil, err
		}
		it.seasonNum, it.episodeNum = resolveEpisodeNumbers(filePath, title, parentTitle, storedSeason, storedEpisode)
		// Sans numéros, TMDB ne peut rien dire de cet épisode. Il n'est pas
		// marqué comme fait : il coûte une ligne de requête, pas un appel.
		if it.seasonNum > 0 && it.episodeNum > 0 {
			queue = append(queue, it)
		}
	}
	return queue, rows.Err()
}

// fetchSeasonTranslation lit en un appel tous les épisodes d'une saison dans
// une langue, par numéro d'épisode.
func fetchSeasonTranslation(showTMDBID, seasonNum int, language string) (map[int]medialang.Text, error) {
	var payload struct {
		Episodes []struct {
			EpisodeNumber int    `json:"episode_number"`
			Name          string `json:"name"`
			Overview      string `json:"overview"`
		} `json:"episodes"`
	}
	_, err := tmdbGet(fmt.Sprintf(
		"/tv/%d/season/%d?language=%s",
		showTMDBID, seasonNum, medialang.TMDBLocale(language),
	), &payload)
	if err != nil {
		return nil, err
	}
	texts := make(map[int]medialang.Text, len(payload.Episodes))
	for _, ep := range payload.Episodes {
		texts[ep.EpisodeNumber] = medialang.Text{
			Title:    strings.TrimSpace(ep.Name),
			Overview: strings.TrimSpace(ep.Overview),
		}
	}
	return texts, nil
}

func translateEpisodes(language string) int {
	queue, err := loadEpisodesToTranslate(language)
	if err != nil {
		log.Printf("TMDB: translations: episode queue (%s): %v", language, err)
		return 0
	}

	type key struct{ showTMDBID, seasonNum int }
	seasons := map[key]map[int]medialang.Text{}
	failed := map[key]bool{}
	saved := 0
	for _, it := range queue {
		k := key{it.showTMDBID, it.seasonNum}
		if failed[k] {
			continue
		}
		texts, ok := seasons[k]
		if !ok {
			texts, err = fetchSeasonTranslation(it.showTMDBID, it.seasonNum, language)
			time.Sleep(translationPause)
			if err != nil {
				log.Printf("TMDB: translations: tv %d season %d (%s): %v", it.showTMDBID, it.seasonNum, language, err)
				failed[k] = true
				continue
			}
			seasons[k] = texts
		}
		// Un épisode absent de TMDB reçoit une ligne vide : la question est
		// réglée, et le texte de base reste affiché.
		if err := medialang.Save(it.id, language, it.showTMDBID, texts[it.episodeNum]); err != nil {
			log.Printf("TMDB: translations: %v", err)
			continue
		}
		saved++
	}
	return saved
}
