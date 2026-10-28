# ADR-0085 — « Disponible » veut dire qu'Onyx le voit

- **Statut :** accepté
- **Date :** 2026-10-28
- **Portée :** le serveur (`server/handlers/library_presence.go`, `enrichCatalogAvailability` et
  `TmdbRequestDetails` dans `server/handlers/tmdb_requests.go`). Côté OnyxHub : son ADR-0016.
  Précise l'ADR-0084.

## Contexte

L'ADR-0084 faisait de la bibliothèque d'Onyx la source qui comble un « unknown » d'OnyxHub.
Il restait le sens inverse : OnyxHub dit « available » quand sorraa (ou Radarr) a fini de
télécharger, avant que le titre soit importé et indexé par Onyx. La carte affichait « disponible »
pour un titre qu'on ne pouvait pas encore lire.

## Décision

Une pastille « disponible » ou « partielle » n'existe que si Onyx a le titre :

- **Carte (catalogue, fiche d'un film)** : `available` ou `partial` sans le titre dans la
  bibliothèque devient `processing` (« en cours »). `unknown` avec le titre reste `available`.
- **Saison (fiche d'une série)** : quand OnyxHub dit `available` ou `partial`, ce sont les
  épisodes qu'Onyx a qui tranchent : tous, `available` ; quelques-uns, `partial` ; aucun,
  `processing`. Un statut de demande (`pending`, `processing`) reste.
- **Série** : `available` si chaque saison l'est ; `partial` sinon ; `processing` si le serveur n'a
  aucun épisode. Un `processing` d'OnyxHub (une saison qui s'importe) reste.

La règle vaut quelle que soit la source d'OnyxHub : Onyx ne sait pas si OnyxHub lit sorraa ou
Radarr, et dans les deux cas « fini de télécharger » n'est pas « lisible ».

## Conséquences

- Un import en cours chez sorraa se voit « en cours » dans Onyx jusqu'au scan de la bibliothèque.
- Si OnyxHub répond `available` pour un titre qu'Onyx a indexé sous un autre identifiant TMDB (ou
  pas encore apparié), la carte reste « en cours » jusqu'à l'appariement.
- Une carte de série du catalogue ne distingue pas ses saisons : une série dont Onyx n'a qu'une
  saison reste « disponible » côté carte si OnyxHub l'est ; sa fiche, elle, dit « partielle ».
