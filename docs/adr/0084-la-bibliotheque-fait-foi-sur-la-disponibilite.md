# ADR-0084 — La bibliothèque d'Onyx fait foi sur la disponibilité d'un titre qu'OnyxHub ignore

- **Statut :** accepté
- **Date :** 2026-10-28
- **Portée :** le serveur (`server/handlers/library_presence.go`, `enrichCatalogAvailability` et
  `TmdbRequestDetails` dans `server/handlers/tmdb_requests.go`). Côté OnyxHub : son ADR-0010.

## Contexte

Le catalogue de demandes et la fiche d'un titre tirent leur pastille (disponible, partielle,
demandé) de la disponibilité qu'OnyxHub rend. OnyxHub la calcule d'après Radarr et Sonarr. Un
film ou une série ajouté à la main, ou par un autre outil, y est inconnu : OnyxHub répond
`unknown`, et la carte n'avait aucune pastille alors que le titre est dans la bibliothèque
d'Onyx et se lit.

OnyxHub applique déjà « inconnu + présent dans Onyx = disponible » sur ses propres cartes
(son ADR-0010). Il ne peut pas l'appliquer à la route que lit Onyx : l'appel porte la clé
d'intégration, sans session, et l'index d'Onyx se lit avec un jeton de compte.

## Décision

Onyx corrige lui-même, il connaît sa bibliothèque :

- **Catalogue.** Après OnyxHub, `applyLibraryPresence` passe de `unknown` à `available` les
  cartes dont l'identifiant TMDB est dans `medias`, en une requête pour la page. La règle vaut
  aussi sans OnyxHub configuré. Un autre statut (demandé, en cours, partiel) vient d'OnyxHub et
  reste.
- **Fiche.** Un film présent passe à `available`. Une série compte les épisodes qu'elle a par
  saison contre ceux de TMDB : saison complète `available`, entamée `partial`, absente inchangée ;
  la série est `available` si toutes ses saisons le sont, `partial` sinon.
- Une carte de série du catalogue, qui n'a pas ces comptes, suit la règle d'OnyxHub :
  `available`.

## Conséquences

- Les pastilles ne dépendent plus de Radarr et Sonarr pour ce que le serveur possède.
- Une panne de la base laisse les statuts d'OnyxHub tels quels (enrichissement, journalisé).
- Une carte de série du catalogue peut afficher « disponible » pour une série dont il manque
  des saisons, tant qu'OnyxHub ne dit rien ; sa fiche, elle, dit « partielle ».
