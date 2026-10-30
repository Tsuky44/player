# ADR-0098 — Recherche interactive des demandes : choisir soi-même la release

- **Statut :** accepté
- **Date :** 2026-10-30
- **Portée :** côté Onyx, `server/mediahub/releases.go`, `server/handlers/mediahub_releases.go`,
  les routes `/api/requests/releases*`, `contract/mediahub/releases.json`, `release_grab.json`,
  `contract/request_releases.json`, et dans l'app `models/request_release.dart`,
  `services/api/request_releases.dart`, `screens/requests/widgets/request_release_sheet.dart` et
  `request_season_panel.dart`. Côté MediaHub, `GET` et `POST /api/integrations/player/v1/releases`
  (`lib/services/interactive-search.ts`). Prolonge l'ADR-0089.

## Contexte

Sur la fiche d'une demande, l'app listait les saisons et leurs épisodes mais n'offrait aucun moyen de
choisir *quelle* release télécharger : quand Sonarr ne trouvait rien de lui-même, ou prenait une
version qui ne convenait pas (langue, définition), il fallait ouvrir MediaHub dans un navigateur et
y faire la recherche interactive. MediaHub la connaît depuis longtemps (Prowlarr pour la liste,
Radarr/Sonarr pour l'envoi), mais seulement dans son interface web, par des *server actions* liées à
la session ; l'API d'intégration v1 n'en disait rien.

## Décision

- **MediaHub l'expose en v1.** `GET /releases?tmdbId=&type=&season=&episode=` liste les releases
  d'un film, d'une saison (`season` seule) ou d'un épisode ; `POST /releases` envoie celle qu'on a
  choisie au téléchargement. Le droit est `interactive_search` (sur `Media` ou `Downloads`, ou la
  gestion des téléchargements), comme dans l'interface. Le ping le dit (`can.interactiveSearch`,
  fonction `interactive-search`).
- **Le gestionnaire choisi cherche, comme pour les demandes.** MediaHub lit `download_manager_movie` et
  `download_manager_tv` (`lib/services/interactive-search.ts`) ; la réponse dit `manager`.
  - **sorraa** : MediaHub retrouve le titre (`GET /media?kind&tmdbId`, ajouté par `POST /media`
    *sans recherche* s'il n'a jamais été demandé), l'unité visée (film, saison ou épisode, dans
    `units`), et appelle `POST /media/{id}/release-searches`. sorraa juge chaque release : la liste
    garde son ordre (la meilleure d'abord) et porte `accepted` et `rejections`, que MediaHub met en
    français. Chaque release a un jeton de 30 minutes (`id`) et **aucune adresse** : sorraa télécharge
    lui-même chez l'indexeur, dont la clé ne sort pas (ADR-0015 de sorraa). Le choix part en
    `POST /grabs` avec le seul jeton ; jeton périmé, `410`, il faut relancer la recherche. Une release
    refusée par le moteur reste prenable à la main : c'est la décision de l'utilisateur.
  - **Radarr/Sonarr** (défaut) : Prowlarr liste, Radarr/Sonarr reçoivent la release, qu'ils ne
    connaissent pas : le choix doit porter `title` et une adresse, et le film, la saison ou l'épisode
    visé est surveillé avant l'envoi.
  - sorraa choisi mais pas réglé : `503`, sans repli sur Radarr/Sonarr, comme une demande.
  Les demandes « automatiques » n'ont rien à changer : `createMediaRequest` passait déjà par le
  gestionnaire choisi (`docs/sorraa-integration.md` de MediaHub). La logique quitte les *server
  actions* de la fiche pour `lib/services/interactive-search.ts` ; la fenêtre de recherche de
  l'interface web de MediaHub reste sur Radarr/Sonarr (`searchArrReleases`), puisqu'elle envoie des
  adresses que sorraa ne rend jamais.
- **Onyx relaie.** `mediahub.Client.Releases` et `Grab` passent par le client unique (ADR-0089) ; les
  routes `GET /api/requests/releases` et `POST /api/requests/releases/grab` sont gardées par
  `manage_settings`, comme la modération : choisir une release déclenche un téléchargement, et un nom
  de compte pris à l'inscription ne doit pas suffire. `GET /api/requests/access` ne rend
  `interactiveSearch` qu'à qui a aussi `manage_settings`, pour que l'app ne propose pas ce que la
  route refuserait. Une cible absurde (épisode sans saison, saison d'un film) est refusée en `400`
  avant tout appel. OnyxHub, ou un MediaHub d'avant la route, donne `501` (`ErrUnsupported`) : une
  `404` sans corps JSON de MediaHub est lue comme « la route n'existe pas ».
- **L'app propose, sans deviner.** Le panneau d'une saison montre « Recherche interactive » dans son
  en-tête, et chaque épisode une loupe, seulement quand `access.canInteractiveSearch` est vrai (lu
  une fois par serveur, `MediaRequestsProvider.loadAccess`). Elle ouvre une fenêtre qui liste les
  releases avec un filtre par mots (nom ou indexeur) et un tri (recommandées, seeders, taille,
  récentes). « Recommandées », l'ordre du compagnon, n'existe et n'est le défaut que quand un moteur
  a jugé les releases (sorraa) ; une release refusée s'efface et dit pourquoi. Un indexeur ne donne ni
  définition ni langue : l'app les lit dans le nom (`RequestRelease.tags` : 1080p, WEB, MULTI,
  VOSTFR…). Toucher une release l'envoie ; elle est alors marquée « envoyée » et ne repart pas.
- **Hors périmètre.** Les films n'ont pas de bouton : la route les accepte, l'écran ne les propose pas
  encore. Avec Radarr/Sonarr, aucun verdict n'est montré (Prowlarr n'en donne pas :
  `accepted` absent, `rejections` vide).

## Conséquences

- La recherche interroge tous les indexeurs : elle dure de quelques secondes à plus de vingt. Le
  serveur attend MediaHub 30 s (`httpx.Long`) et l'app 30 s (intercepteur d'`ApiClient`) ; au-delà
  l'écran dit « Impossible de charger les releases » et propose de réessayer. Si cela arrive en
  pratique, il faudra un client à échéance plus longue pour cette seule route.
- Aucune release n'est mise en cache : chaque ouverture refait la recherche, pour ne pas montrer une
  liste périmée de seeders (et sorraa compte chaque recherche dans les limites de ses indexeurs).
- Chercher une saison que personne n'a demandée ajoute le titre à la bibliothèque de sorraa, sans
  rien télécharger : il y reste même si l'on n'envoie aucune release.
- Le contrat grandit de fichiers (`releases.json`, `releases_arr.json`, `release_grab.json`,
  `release_grab_arr.json`, `request_releases.json`) et d'un champ (`can.interactiveSearch`), gardés des
  deux côtés comme ceux de l'ADR-0089. `guid` reste, égal à `id`, pour les clients d'avant sorraa. Les
  champs ajoutés sont compatibles : un Onyx ancien ignore le droit, un MediaHub ancien ne le dit pas.
- L'envoi n'attend pas que Sonarr ait fini : le titre reste « en cours » jusqu'à l'import, que
  l'évènement `media.imported` de MediaHub signale comme pour une demande ordinaire.
