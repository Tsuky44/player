# ADR-0073 — Ce que la bibliothèque a par TMDB, un lien qui ouvre une fiche, et « Mes demandes »

- **Statut :** accepté
- **Date :** 2026-10-20
- **Portée :** le serveur (`server/handlers/library_tmdb_index.go`, `MediaHubMyRequests` dans
  `server/handlers/mediahub.go`, les routes `GET /api/library/tmdb-index` et
  `GET /api/requests/mine` dans `server/main.go`, capacités `library_tmdb_index` et
  `my_requests` dans `server/handlers/ping.go`) et l'app (`app/lib/navigation/media_link.dart`,
  `app/lib/screens/requests/my_requests_screen.dart`, `app/lib/models/my_request.dart`,
  `app/lib/services/api/my_requests.dart`). Côté OnyxHub : son ADR-0010.

## Contexte

OnyxHub montre le catalogue TMDB à côté d'Onyx. Il ne savait pas ce qu'Onyx avait indexé :
il le devinait par Radarr et Sonarr, qui disent ce qui est sur le disque. Et il ne pouvait
pas renvoyer vers le lecteur. `/api/media-identities` rend chaque épisode de la
bibliothèque : beaucoup trop pour cette question. Dans l'autre sens, l'app envoyait des
demandes à OnyxHub sans pouvoir en suivre l'avancement.

## Décision

- **`GET /api/library/tmdb-index`** (`RequireAuth` : tout compte voit déjà toute la
  bibliothèque) rend `{ "movies": { "<tmdb>": id }, "shows": { "<tmdb>": id } }`. Un titre
  en plusieurs versions donne sa plus ancienne fiche, comme le rattachement des listes
  (ADR-0070).
- **L'app web ouvre une fiche depuis `?movie=ID` ou `?show=ID`.** C'est le lien « Lire dans
  Onyx » d'OnyxHub. Le lien est lu au démarrage, comme `?tv=CODE`, puis la fiche s'ouvre
  par-dessus les onglets une fois la coquille prête, une seule fois.
- **`GET /api/requests/mine`** (`request_media`, le même droit que pour envoyer une
  demande) relaie `GET {OnyxHub}/api/request` au nom du compte, réponse telle quelle.
  L'écran « Mes demandes », ouvert depuis l'onglet Demander, montre chaque lot, son statut
  et sa progression. Il n'apparaît que si le serveur annonce `my_requests`.

## Conséquences

- MediaHub n'a pas `GET /api/request` : avec lui, la route renvoie son erreur et l'app
  n'ouvre pas l'écran tant que la capacité manque.
- La réponse de « Mes demandes » est celle d'OnyxHub : elle est épinglée par le test de
  contrat d'OnyxHub, pas par `contract/` d'Onyx.
- Le lien de fiche ne marche que sur le web. Sur mobile et sur la télé, il n'y a pas
  d'URL de lancement à lire.
