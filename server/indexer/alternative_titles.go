package indexer

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"

	"project-player/server/httpx"
	"project-player/server/models"
	"project-player/server/tmdb"
)

// alternativeTitleCandidates borne le repli : chaque candidat coûte un appel
// TMDB, et la bonne fiche figure dans les premiers résultats puisque la
// recherche TMDB indexe déjà les titres alternatifs.
const alternativeTitleCandidates = 5

// rescueWithAlternativeTitles relance l'appariement sur les titres alternatifs
// et les traductions des meilleurs candidats.
//
// Un dossier « Farmer Wants a Wife » pour « L'amour est dans le pré » :
// TMDB renvoie bien la fiche (il cherche aussi dans les titres alternatifs),
// mais ni son titre français ni son titre original ne ressemblent au nom du
// dossier, et le score la rejetait. Les seuils restent ceux de l'ADR-0002 :
// seul un titre alternatif réellement proche fait passer un candidat.
func rescueWithAlternativeTitles(pool []tmdbSearchResult, targetTitle string, targetYear int, mediaType models.MediaType) (tmdbSearchResult, float64, bool) {
	var enriched []tmdbSearchResult
	for _, r := range pool {
		if len(enriched) >= alternativeTitleCandidates {
			break
		}
		if targetYear > 0 {
			if ry := tmdbResultYear(r, mediaType); ry > 0 && absInt(ry-targetYear) > 1 {
				continue
			}
		}
		r.AltTitles = fetchTMDBAlternativeTitles(r.ID, mediaType)
		if len(r.AltTitles) > 0 {
			enriched = append(enriched, r)
		}
	}
	if len(enriched) == 0 {
		return tmdbSearchResult{}, 0, false
	}
	best := pickBestTMDBResult(enriched, targetTitle, targetYear, mediaType)
	score := scoreTMDBResult(best, targetTitle, targetYear, mediaType)
	if !isConfidentTMDBMatch(best, targetTitle, targetYear, mediaType, score) {
		return tmdbSearchResult{}, 0, false
	}
	log.Printf("Identify: %q matched TMDB id=%d through an alternative title", targetTitle, best.ID)
	return best, score, true
}

// Les titres alternatifs d'une fiche ne changent pas pendant un scan, et une
// série est identifiée une fois par épisode : même cycle de vie que searchCache.
var (
	altTitlesCache   = map[int][]string{}
	altTitlesCacheMu sync.Mutex
)

func altTitlesCacheKey(tmdbID int, mediaType models.MediaType) int {
	// Films et séries ont des espaces d'identifiants TMDB distincts.
	if mediaType == models.TypeShow {
		return -tmdbID
	}
	return tmdbID
}

func resetAltTitlesCache() {
	altTitlesCacheMu.Lock()
	altTitlesCache = map[int][]string{}
	altTitlesCacheMu.Unlock()
}

type tmdbAlternativeTitle struct {
	Title string `json:"title"`
}

type tmdbAlternativeTitlesDetails struct {
	AlternativeTitles struct {
		Titles  []tmdbAlternativeTitle `json:"titles"`  // films
		Results []tmdbAlternativeTitle `json:"results"` // séries
	} `json:"alternative_titles"`
	Translations tmdbTranslationsResponse `json:"translations"`
}

// fetchTMDBAlternativeTitles renvoie les titres alternatifs et les titres
// traduits d'une fiche, en un seul appel (append_to_response).
func fetchTMDBAlternativeTitles(tmdbID int, mediaType models.MediaType) []string {
	apiKey := tmdbAPIKey()
	if apiKey == "" || tmdbID <= 0 {
		return nil
	}
	key := altTitlesCacheKey(tmdbID, mediaType)
	altTitlesCacheMu.Lock()
	cached, ok := altTitlesCache[key]
	altTitlesCacheMu.Unlock()
	if ok {
		return cached
	}

	endpoint := "movie"
	if mediaType == models.TypeShow {
		endpoint = "tv"
	}
	u := fmt.Sprintf(
		"/%s/%d?append_to_response=alternative_titles,translations",
		endpoint, tmdbID,
	)
	resp, err := tmdb.Get(httpx.Standard, u)
	if err != nil {
		log.Printf("TMDB alternative titles %d: %v", tmdbID, err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Pas de mise en cache : une erreur passagère ne doit pas priver le
		// reste du scan de ce repli.
		return nil
	}
	var d tmdbAlternativeTitlesDetails
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		log.Printf("TMDB alternative titles %d: %v", tmdbID, err)
		return nil
	}

	seen := map[string]bool{}
	var titles []string
	add := func(title string) {
		title = strings.TrimSpace(title)
		norm := normalizeForMatch(title)
		if norm == "" || seen[norm] {
			return
		}
		seen[norm] = true
		titles = append(titles, title)
	}
	for _, t := range d.AlternativeTitles.Titles {
		add(t.Title)
	}
	for _, t := range d.AlternativeTitles.Results {
		add(t.Title)
	}
	for _, tr := range d.Translations.Translations {
		add(tr.Data.Title)
		add(tr.Data.Name)
	}

	altTitlesCacheMu.Lock()
	altTitlesCache[key] = titles
	altTitlesCacheMu.Unlock()
	return titles
}
