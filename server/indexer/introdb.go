package indexer

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"

	"project-player/server/httpx"
)

// introDBBase est l'API v4 de TheIntroDB. La lecture (GET /media) n'exige pas
// de clé : elle est comptée par adresse IP, 5 000 appels par jour, et le client
// partagé de httpx rejoue déjà un refus 429 passager.
const introDBBase = "https://api.theintrodb.org/v4/media"

// ErrIntroDBThrottled dit que TheIntroDB a refusé l'appel pour excès de
// requêtes, même après les nouvelles tentatives du client : inutile d'insister
// sur le reste de la saison.
var ErrIntroDBThrottled = errors.New("TheIntroDB a refusé l'appel (trop de requêtes)")

// IntroDBSegment est un passage d'un épisode. Les bornes sont facultatives :
// un début absent veut dire « dès le début » (intro, récap) et une fin absente
// « jusqu'à la fin du média » (générique, aperçu).
type IntroDBSegment struct {
	StartMs *int `json:"start_ms"`
	EndMs   *int `json:"end_ms"`
}

// IntroDBResponse est la réponse de GET /media : chaque type de passage est une
// liste, car la base peut en connaître plusieurs (un générique suivi d'une
// scène post-générique, par exemple).
type IntroDBResponse struct {
	Intro   []IntroDBSegment `json:"intro"`
	Recap   []IntroDBSegment `json:"recap"`
	Credits []IntroDBSegment `json:"credits"`
	Preview []IntroDBSegment `json:"preview"`
}

// EpisodeMarkers sont les repères retenus pour un épisode, en secondes. 0/0
// veut dire « rien trouvé » ; un début d'intro à 0 est un vrai début.
type EpisodeMarkers struct {
	IntroStart, IntroEnd int
	OutroStart, OutroEnd int
}

func (m EpisodeMarkers) hasIntro() bool { return m.IntroEnd > m.IntroStart }
func (m EpisodeMarkers) hasOutro() bool { return m.OutroEnd > m.OutroStart }

// introDBAdjacentGap est l'écart maximal entre la fin d'un récap et le début de
// l'intro pour que les deux ne fassent qu'un seul passage à sauter.
const introDBAdjacentGap = 30

// introDBFallbackCredits borne un générique sans fin quand la durée du fichier
// est inconnue : le maximum que l'API accepte pour un générique.
const introDBFallbackCredits = 1800

// secondsRange lit un passage en secondes. La fin est obligatoire ; un début
// absent vaut 0.
func (s IntroDBSegment) secondsRange() (start, end int, ok bool) {
	if s.EndMs == nil {
		return 0, 0, false
	}
	if s.StartMs != nil {
		start = *s.StartMs / 1000
	}
	return start, *s.EndMs / 1000, true
}

// earliestPlausible rend le premier passage vraisemblable de la liste : la base
// peut en renvoyer plusieurs, et une valeur aberrante (un « intro » qui couvre
// la moitié de l'épisode) ne doit pas prendre la place d'une bonne.
func earliestPlausible(segments []IntroDBSegment, durationSec int) (start, end int, ok bool) {
	for _, s := range segments {
		st, en, valid := s.secondsRange()
		if !valid || !IsPlausibleIntroRange(st, en, durationSec) {
			continue
		}
		if !ok || st < start {
			start, end, ok = st, en, true
		}
	}
	return start, end, ok
}

// PickMarkers choisit, parmi ce que TheIntroDB répond, les repères à garder.
//
// Intro et récap ne forment une seule fenêtre que s'ils se suivent : avec un
// récap en pré-générique (0-60 s) et une intro à 300 s, les fusionner ferait
// sauter 5 minutes d'épisode. Séparés, on garde l'intro seule.
//
// Pour le générique, on prend le plus précoce qui tombe dans la seconde moitié
// de l'épisode : c'est là que l'épisode suivant se propose, la scène
// post-générique qui vient après ne doit pas le repousser.
func PickMarkers(resp *IntroDBResponse, durationSec int) EpisodeMarkers {
	var m EpisodeMarkers
	if resp == nil {
		return m
	}

	iStart, iEnd, hasIntro := earliestPlausible(resp.Intro, durationSec)
	rStart, rEnd, hasRecap := earliestPlausible(resp.Recap, durationSec)
	switch {
	case hasIntro && hasRecap && rStart <= iStart && iStart-rEnd <= introDBAdjacentGap &&
		IsPlausibleIntroRange(rStart, iEnd, durationSec):
		m.IntroStart, m.IntroEnd = rStart, iEnd
	case hasIntro:
		m.IntroStart, m.IntroEnd = iStart, iEnd
	case hasRecap:
		m.IntroStart, m.IntroEnd = rStart, rEnd
	}

	found := false
	for _, s := range resp.Credits {
		if s.StartMs == nil {
			continue
		}
		start := *s.StartMs / 1000
		if durationSec > 0 && start < durationSec/2 {
			continue
		}
		end := start + introDBFallbackCredits
		if durationSec > start {
			end = durationSec
		}
		if s.EndMs != nil {
			end = *s.EndMs / 1000
		}
		if end <= start || (found && start >= m.OutroStart) {
			continue
		}
		m.OutroStart, m.OutroEnd, found = start, end, true
	}
	return m
}

// introDBMedia désigne une série auprès de TheIntroDB : son identifiant TMDB
// de préférence — c'est la numérotation de la médiathèque —, à défaut l'IMDb
// déjà connu.
type introDBMedia struct {
	TMDBID int
	IMDbID string
}

func (m introDBMedia) valid() bool { return m.TMDBID > 0 || m.IMDbID != "" }

// FetchSegmentsFromIntroDB interroge TheIntroDB pour un épisode. La durée du
// fichier lui permet de reconnaître la version (release) dont viennent les
// horodatages ; elle n'est envoyée que dans la plage que l'API accepte.
// Une réponse sans donnée (404) rend nil, pas une erreur.
func FetchSegmentsFromIntroDB(media introDBMedia, season, episode, durationSec int) (*IntroDBResponse, error) {
	q := url.Values{}
	if media.TMDBID > 0 {
		q.Set("tmdb_id", strconv.Itoa(media.TMDBID))
	} else {
		q.Set("imdb_id", media.IMDbID)
	}
	q.Set("season", strconv.Itoa(season))
	q.Set("episode", strconv.Itoa(episode))
	if ms := durationSec * 1000; ms >= 300000 && ms <= 21600000 {
		q.Set("duration_ms", strconv.Itoa(ms))
	}

	resp, err := httpx.Standard.Get(introDBBase + "?" + q.Encode())
	if err != nil {
		return nil, fmt.Errorf("failed to fetch from TheIntroDB: %v", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return nil, nil // aucune donnée pour l'instant : réponse normale
	case http.StatusTooManyRequests:
		return nil, ErrIntroDBThrottled
	default:
		return nil, fmt.Errorf("TheIntroDB API returned status %d", resp.StatusCode)
	}

	var result IntroDBResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode TheIntroDB response: %v", err)
	}
	return &result, nil
}
