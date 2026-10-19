# ADR-0068 — Affiche choisie parmi TMDB et Fanart.tv

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** `server/artwork`, `server/handlers/media_artwork.go`, `server/indexer` (respect de la
  marque), `app/lib/widgets/global/poster_picker_sheet.dart`, fiches film et série, réglages
  « Métadonnées ».

## Contexte

L'affiche d'un film ou d'une série était celle que TMDB donne par défaut dans la langue des
métadonnées, sans autre choix. « Corriger la fiche » ne changeait l'affiche qu'en changeant
d'œuvre. Emby, lui, propose pour la même œuvre toutes les affiches connues de TMDB et de
Fanart.tv, et garde celle qu'on choisit.

Deux pièges : l'enrichissement automatique (`enrichMediaRecord`, rattrapage, « tout redétecter »)
réécrivait `poster_url` à chaque passage, et une série prête son affiche à ses saisons et
épisodes sans image propre (`backfillEpisodePosters`).

## Décision

### Qui

Les trois routes exigent `manage_library` : c'est réécrire la médiathèque de toute la maison.
Un administrateur a toujours ce droit (ADR-0001). L'app ne montre l'entrée qu'aux comptes qui
l'ont ; la garde réelle reste `RequirePermission`.

### Sources

- **TMDB**, toujours : `/{movie|tv}/{id}/images`, limité à la langue de l'interface, l'anglais et
  les affiches sans texte. Enregistrée en `w500`, la taille que l'indexeur pose déjà.
- **Fanart.tv**, seulement si une clé est réglée (`fanart_api_key`, ou `FANART_API_KEY`). Pas de
  clé de projet embarquée : elle serait publique dans un dépôt source-available. Les séries s'y
  cherchent par identifiant TheTVDB, demandé à TMDB. La clé passe par l'en-tête `api-key`, jamais
  par l'URL, pour ne pas finir dans le journal (ADR-0050). L'affiche est enregistrée à sa taille
  d'origine (≈ 1000 × 1426) : il n'existe pas d'intermédiaire, `/preview/` sert aux vignettes.

Les deux sont interrogées en parallèle, bornées à 15 s ; une source en panne est journalisée et
laissée de côté. Ordre : langue de l'interface, puis sans texte, puis anglais, puis le reste ;
les plus appréciées d'abord dans chaque groupe.

### Ce qui est enregistré

`PUT /api/media/:id/poster` n'accepte qu'une adresse `https` de `image.tmdb.org` ou
`assets.fanart.tv`. L'adresse est chargée par toutes les apps de la maison : une adresse libre
leur ferait joindre n'importe quel hôte.

L'affiche choisie pose `medias.poster_locked` (migration 26). Tant qu'elle est posée :

- l'enrichissement ne remplace plus `poster_url` ;
- une ré-identification **vers la même fiche TMDB** la garde ; vers une autre fiche, l'affiche
  choisie n'a plus de sens et la marque tombe.

Les saisons et épisodes d'une série qui portaient son ancienne affiche suivent le changement ;
ceux qui ont leur propre image la gardent.

`DELETE /api/media/:id/poster` lève la marque et remet l'affiche par défaut de TMDB. Si TMDB ne
répond pas, seule la marque tombe, et le prochain rattrapage fera le reste.

### Écarté

- **Télécharger l'image sur le serveur** (comme Emby) : coûte du disque et une route de service
  d'images, pour un gain nul tant que les apps chargent déjà TMDB directement.
- **Une adresse libre** (coller une URL) : voir plus haut.
- **Fond et logo** : le fond et le logo viennent de TMDB à chaque ouverture de la fiche et ne sont
  pas stockés ; les rendre choisissables demande de les stocker d'abord. Hors périmètre.

## Conséquences

- `GET /api/ping` annonce `poster_picker` ; l'app dit « serveur à mettre à jour » plutôt que de
  lire un 404.
- Une affiche Fanart.tv pèse plus lourd qu'une `w500` de TMDB dans les grilles ; `AppNetworkImage`
  la décode à la taille affichée, seul le transfert est plus long.
- `indexer/metadata.go` est passé sous 800 lignes : les corrections manuelles vivent dans
  `indexer/manual_match.go`.
