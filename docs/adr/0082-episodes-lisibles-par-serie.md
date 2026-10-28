# ADR-0082 — Les épisodes lisibles d'une série, par identifiant TMDB

- **Statut :** accepté
- **Date :** 2026-10-27
- **Portée :** `server/handlers/library_show_episodes.go`, la route
  `GET /api/library/shows/:tmdb/episodes` dans `server/main.go`, la capacité
  `library_show_episodes` dans `server/handlers/ping.go`, `contract/onyxhub/library_show_episodes.json`.
  Côté OnyxHub : son ADR-0014.

## Contexte

OnyxHub liste les épisodes d'une saison d'après TMDB et marque « Disponible » ceux qui sont
sur le disque. Il le lisait chez sorraa ou Sonarr, donc ce qui a été *importé* par eux : un
épisode copié à la main dans la bibliothèque, lisible dans Onyx, restait « manquant ».
Les routes d'Onyx qui rendent des épisodes (`/api/shows/:id/seasons`, `/api/seasons/:id/episodes`)
rendent des fiches complètes, complètent par TMDB et rafraîchissent des titres : trop lourd pour
une question qui ne porte que sur des numéros, posée à chaque saison ouverte.

## Décision

- **`GET /api/library/shows/:tmdb/episodes`** (`RequireAuth`, comme `tmdb-index`) rend
  `{ "seasons": { "<n>": [épisodes] } }` : les numéros des épisodes qui ont un fichier, pour
  toutes les saisons d'un coup, en une requête indexée sur `medias`. Plusieurs fiches de série
  de même identifiant TMDB (deux dossiers) s'additionnent. Un épisode sans fichier n'y est pas.
- Le serveur annonce `library_show_episodes` : OnyxHub garde son comportement d'avant face à un
  Onyx plus ancien.

## Conséquences

- Onyx dit seul ce qui est « Disponible » au niveau de l'épisode, comme il le dit déjà pour les
  films et les séries (ADR-0073).
- Une requête SQL par série ouverte, pas d'appel TMDB, aucun effet de bord.
