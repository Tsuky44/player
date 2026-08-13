# Les cartes poster partagent un seul rayon et un seul traitement de survol

Written against: `059dcc264c305f18369db4cd1a350bc8514149b6` (2026-07-18)

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web ; le rayon de coin est visible sur les quatre cibles, le survol seulement là où il y a un pointeur (desktop et web). Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine.

## Evidence chain

- Surface : les rows et grilles de posters — Accueil (`app/lib/screens/home/home_screen.dart:221-256`), Films (`movies_screen.dart:146`), Séries (`shows_screen.dart:141`), recherche (`search_results_screen.dart:91`), Demandes (`requests_screen.dart:230`).
- Problème : trois cartes poster coexistent avec trois traitements différents, dont deux sortent du contrat.
  - `MediaCard` (`app/lib/widgets/global/media_card.dart`) : poster à rayon 12 (ligne 59) ; survol = liseré blanc **1.5 px à 18 %** + voile noir 22 % + icône play (lignes 61-78).
  - `ContinueWatchingCard` (`app/lib/widgets/global/continue_watching_card.dart`) : poster clippé à **rayon 6** (lignes 107 et 121) — hors de la plage documentée — et survol **sans aucun liseré**, juste un voile noir 40 % avec une icône 52 px (lignes 118-131). `MediaPoster` reçoit d'ailleurs `borderRadius: 0` (ligne 112) parce qu'un `ClipRRect(6)` externe le remplace, alors que `MediaPoster` a déjà `borderRadius = 12` par défaut (`media_poster.dart:23`).
  - `RequestMediaCard` (`app/lib/screens/requests/widgets/request_media_card.dart`) : poster à rayon 12 (lignes 22 et 31), mais **aucun survol** — seulement le ripple de l'`InkWell`.
  - Les deux premières sont montées côte à côte sur l'Accueil, par le même `MediaRow` (`app/lib/widgets/global/media_row.dart:90` pour `ContinueWatchingCard`, `:101` pour `MediaCard`) : la row « Reprendre la lecture » et la row « Films récents » sont visibles simultanément (`home_screen.dart:221-245`), avec deux arrondis différents à quelques pixels d'écart.
- Design evidence : `PROJECT_DESIGN.md` §8 Component Styling, « Media cards » — « Radius 12–14 ; no card fill behind poster » et « Hover desktop: 1px white 16% stroke + slight brightness ; play affordance optionnelle ».
- Owner : `app/lib/widgets/global/media_poster.dart` (défaut `borderRadius = 12`) pour le rayon ; les trois cartes pour le survol.
- Scope and affected surfaces : `app/lib/widgets/global/media_card.dart`, `app/lib/widgets/global/continue_watching_card.dart`, `app/lib/screens/requests/widgets/request_media_card.dart`.
- Uncertainty : le brief donne une plage de rayon (12–14) ; le dépôt a déjà tranché sur 12 via le défaut de `MediaPoster` et deux cartes sur trois. Le liseré de survol est une valeur unique (1 px, blanc 16 %), sans ambiguïté.

## Design decision

Aligner les trois cartes poster sur un seul traitement : rayon 12 et, au survol pointeur, un liseré blanc de 1 px à 16 %.

Corriger uniquement `ContinueWatchingCard` laisserait `MediaCard` à 1.5 px / 18 % et `RequestMediaCard` sans survol — c'est-à-dire trois variantes remplacées par deux. La décision porte donc sur les trois consommateurs à la fois, ce qui est la seule façon de faire disparaître le motif parallèle plutôt que de le réduire.

## Reuse

- Owner existant : `MediaPoster` et son défaut `borderRadius = 12` (`app/lib/widgets/global/media_poster.dart:23`) — il suffit de cesser de le contourner.
- Exemplar de la structure de survol : `app/lib/widgets/global/media_card.dart:39-78` — `MouseRegion` + `setState(_hovered)` + `DecoratedBox` conditionnel en `Stack`.

Aucun nouveau primitive n'est requis. **Ne pas** extraire une carte poster partagée : les trois cartes diffèrent par leur contenu (progression, menu contextuel, badges de statut) et la seule chose qu'elles ont en commun ici sont deux valeurs, pas une composition. La répétition seule ne justifie pas un composant partagé.

## Changes

1. `app/lib/widgets/global/continue_watching_card.dart`
   - Change : supprimer le `ClipRRect(borderRadius: BorderRadius.circular(6))` de la ligne 107 et son `borderRadius: 0` associé (ligne 112) — laisser `MediaPoster` clipper avec son défaut de 12. Passer le `borderRadius` du conteneur de survol (ligne 121) de 6 à 12. Ajouter au survol un `Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1)` sur ce même conteneur.
   - Preserve : le voile de survol, l'icône `play_circle_fill_rounded` 52 px, la barre de progression en bas du poster, le menu contextuel sur clic droit et appui long (`onSecondaryTapDown` / `onLongPressStart`), les constantes `cardWidth` / `posterHeight`, le `BoxFit.cover`.
   - Verify : sur l'Accueil, les vignettes « Reprendre la lecture » ont le même arrondi que « Films récents », et le survol fait apparaître un liseré clair.

2. `app/lib/widgets/global/media_card.dart`
   - Change : dans le `DecoratedBox` de survol (lignes 61-70), passer le liseré de `alpha: 0.18, width: 1.5` à `alpha: 0.16, width: 1`.
   - Preserve : le rayon 12, le voile noir 22 %, l'icône play dimensionnée selon `compact`, la barre de progression conditionnelle, les libellés titre/année.
   - Verify : le liseré reste perceptible sur poster clair comme sur poster sombre.

3. `app/lib/screens/requests/widgets/request_media_card.dart`
   - Change : convertir le widget en `StatefulWidget`, l'envelopper d'un `MouseRegion` qui suit `_hovered`, et ajouter dans le `Stack` (après le `ClipRRect` de la ligne 30, avant les badges) un `DecoratedBox` conditionnel avec `BorderRadius.circular(12)` et `Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1)`.
   - Preserve : l'`InkWell` et son `onTap`, le rayon 12 existant, le badge de type en haut à gauche, la pastille de statut en haut à droite, les placeholders de chargement et d'erreur.
   - Verify : au survol, une carte de la grille Demandes réagit comme une carte de la grille Films.

## Scope

- Inherit : toutes les rows et grilles de posters — Accueil, Films, Séries, recherche, Demandes, sur les quatre cibles.
- Verify : `MediaRow` (`media_row.dart:35-101`) dimensionne les cartes via `AppLayout.mediaRowCardWidth` (118 en compact, 150 sinon) — confirmer que le rayon 12 ne paraît pas excessif à 118 px de large. Vérifier aussi la barre de progression de `ContinueWatchingCard`, positionnée en bas du poster : elle doit rester alignée sur le nouveau clip à 12.
- Exclude : `EpisodeTile` (`app/lib/widgets/global/episode_tile.dart:138`, rayon 4) — c'est une vignette d'épisode 16:9 dans une liste, pas une carte poster ; `PROJECT_DESIGN.md` §8 « Media cards » ne la gouverne pas. Exclure également le hero (`hero_carousel.dart`), les tailles de carte, les aspect ratios et tout changement de contenu.

## Validation

- Product : depuis l'Accueil, survoler puis ouvrir une vignette « Reprendre la lecture » et une carte « Films récents ». Les deux doivent s'ouvrir comme avant ; le menu contextuel de « Reprendre la lecture » (marquer comme vu / masquer) doit rester accessible au clic droit et à l'appui long.
- Interface : Accueil (rows côte à côte), Films, Séries, résultats de recherche, grille Demandes — aux largeurs 375, 600, 899, 901 et 1440 px. Tester avec un poster manquant (placeholder), un poster très clair et un poster très sombre, et un élément à 1 % et à 98 % de progression.
- System : après le changement, aucune carte poster ne doit clipper à une autre valeur que le défaut de `MediaPoster`, et le liseré de survol doit avoir la même valeur partout.
- Repository :
  - `grep -rn "circular(6)" app/lib/widgets/global/continue_watching_card.dart` → aucun résultat.
  - `grep -rn "alpha: 0.18" app/lib/widgets/global/media_card.dart` → aucun résultat.
  - `cd app && flutter analyze lib/widgets/global/media_card.dart lib/widgets/global/continue_watching_card.dart lib/screens/requests/widgets/request_media_card.dart` → `No issues found`.

## Stop conditions

- Stop si retirer le `ClipRRect` externe de `ContinueWatchingCard` casse le positionnement de la barre de progression ou du dégradé de bas de vignette : signaler plutôt que de réintroduire un rayon différent.
- Stop si passer `RequestMediaCard` en `StatefulWidget` entre en conflit avec la façon dont `requests_screen.dart:230` la construit (clé, recyclage de grille).
- Stop si le périmètre doit s'étendre à une refonte de carte partagée : ce plan ne fait qu'aligner deux valeurs.

## Design documentation

- Après acceptation et validation : préciser dans `PROJECT_DESIGN.md` §8 « Media cards » que le rayon retenu dans la plage 12–14 est **12**, porté par le défaut de `MediaPoster`, et que le survol pointeur est un liseré blanc 1 px à 16 % sur les trois cartes poster. Ne pas modifier `design.md`, qui est le brief incumbent superseded.
