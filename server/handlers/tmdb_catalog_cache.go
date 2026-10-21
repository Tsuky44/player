package handlers

import (
	"net/http"
	"time"

	"project-player/server/ttlcache"
)

// Les pages du catalogue de demandes (tendances, recherche, découverte) en
// cache dix minutes, comme les listes d'OnyxHub.
//
// TmdbRequestCatalog rappelait TMDB à chaque page : l'app précharge
// maintenant la page suivante pendant qu'on lit la courante, puis la demande
// pour de bon en arrivant en bas, et revenir sur l'écran rechargeait tout.
// Un aller-retour TMDB (200 à 400 ms) par page devient une lecture en
// mémoire. Dix minutes : une tendance ou un résultat de recherche ne bouge
// pas plus vite, et le statut de disponibilité, lui, n'est pas en cache.
const (
	tmdbCatalogPageTTL        = 10 * time.Minute
	tmdbCatalogPageMaxEntries = 256
)

var tmdbCatalogPages = ttlcache.New[tmdbCatalogResponse](tmdbCatalogPageTTL, tmdbCatalogPageMaxEntries)

// cachedTMDBCatalogPage rend la page TMDB de tmdbURL (chemin et requête, sans
// la clé), depuis le cache si elle y est. Un échec n'est pas retenu. La page
// rendue est partagée : l'appelant n'en modifie pas les résultats.
func cachedTMDBCatalogPage(client *http.Client, tmdbURL string) (tmdbCatalogResponse, error) {
	if page, ok := tmdbCatalogPages.Get(tmdbURL); ok {
		return page, nil
	}
	var page tmdbCatalogResponse
	if err := fetchTMDBCatalogPage(client, tmdbURL, &page); err != nil {
		return tmdbCatalogResponse{}, err
	}
	tmdbCatalogPages.Put(tmdbURL, page)
	return page, nil
}
