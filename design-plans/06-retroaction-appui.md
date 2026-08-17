# Les cartes répondent à l'appui, pas seulement au survol

Written against: `c549dde` (2026-08-15)

Dépend du plan [04 — Owner de mouvement](04-owner-de-mouvement.md), qui doit être exécuté avant. Indépendant du plan 05.

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web ; ce plan vaut pour les quatre cibles, et c'est sur les cibles tactiles qu'il change le plus. Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine.

Le dépôt a **deux** cartes de contenu, et une seule est un owner partagé :

- `PosterCard` (`app/lib/widgets/global/poster_card.dart`) — l'owner de toutes les affiches. Consommé par `MediaCard` (`media_card.dart:34`, lui-même monté par les grilles Films, Séries, recherche et par `MediaRow`), `RequestMediaCard` (`request_media_card.dart:21`, grille Demandes) et `CatalogPosterCard` (`media_detail_widgets.dart:615`, écrans Collection et Personne). **Corriger ce fichier corrige six écrans.**
- `ContinueWatchingCard` (`app/lib/widgets/global/continue_watching_card.dart`) — la vignette « Reprendre la lecture », consommée uniquement par `MediaRow` (`media_row.dart:90`). Elle est séparée parce qu'elle a deux cibles de tap distinctes et un menu contextuel, ce que `PosterCard` n'a pas.

## Evidence chain

- Surface : toutes les cartes de contenu de l'app — Accueil (rows), Films, Séries, recherche, Demandes, Collection, Personne, et le bandeau « titres liés » d'une fiche de demande.
- Problème : la réponse à un appui est absente ou tardive, et n'existe pratiquement que pour un pointeur.
  - `PosterCard` (`poster_card.dart:62-101`) : un `MouseRegion` alimente `_hovered`, et le liseré blanc 16 % + le voile + l'icône play ne sont peints **que** sous `_hovered` (`poster_card.dart:79-101`). Sur Android, sur tablette et sur tout écran tactile, aucun de ces retours n'existe. Il ne reste que l'ondulation Material de l'`InkWell` (`poster_card.dart:65-67`) — l'idiome Android, et comme cet `InkWell` enveloppe toute la `Column` (affiche + titre + sous-titre, `:68-145`), l'ondulation se peint aussi sous les deux lignes de texte.
  - `ContinueWatchingCard` (`continue_watching_card.dart:97-98`) : `GestureDetector` nu autour de l'affiche. **Aucune** réponse à l'appui — ni ondulation, ni échelle, ni voile. La première ligne de l'Accueil, celle sur laquelle on tape le plus, ne renvoie rien avant que la route ne pousse.
  - `_RelatedCard` (`screens/requests/widgets/request_related_slider.dart:70-73`) est le seul endroit qui anime une carte : `AnimatedScale(scale: _hovered ? 1.03 : 1, duration: 160ms)` — mais au **survol**, pas à l'appui, et ni `1.03` ni `160 ms` n'existent ailleurs dans le produit.
- Design evidence :
  - `PROJECT_DESIGN.md` §10 (ligne 128) : « Motion: 180–280ms ease-out » — `160 ms` est hors plage, `0 ms` aussi.
  - `PROJECT_DESIGN.md` §8 (ligne 95) : « Hover desktop: 1px white 16% stroke + slight brightness ; play affordance optionnelle ». Le brief qualifie ce traitement de **desktop** — il ne prétend donc pas couvrir le tactile, qui n'a aujourd'hui rien du tout.
  - `PROJECT_DESIGN.md` §4 (ligne 38) : « Non-transferable: over-glass everywhere, **scale-on-focus 1.1 agressif** » — une mise à l'échelle interactive est admise, mais discrète.
  - `PROJECT_DESIGN.md` §3 (ligne 55) : « Emotional tone: calme, confiance, **contrôle effortless** ».
  - Skill apple-design §1 : « respond on pointer-down, not on release » ; « feedback must be continuous during the interaction, not just at the end ». §10 : « Tap: highlight on touch-*down* (instant), commit on touch-*up*. Allow cancel-by-dragging-away ». §16 Craft : « responsive animations that give immediate, natural feedback ».
- Owner : `PosterCard` est déjà l'owner des affiches et n'a pas besoin d'être créé. Ce qui manque est le primitive d'interaction lui-même — l'état d'appui, le survol et le focus — aujourd'hui recodé (partiellement) dans chaque carte.
- Scope and affected surfaces : `app/lib/widgets/global/pressable.dart` (nouveau), `app/lib/widgets/global/poster_card.dart`, `app/lib/widgets/global/continue_watching_card.dart`.
- Uncertainty :
  - Remplacer l'`InkWell` de `PosterCard` supprime l'ondulation Material — c'est **l'intention** (§1 : le retour doit être instantané et à l'appui, pas une onde qui se propage) et c'est cohérent avec `PROJECT_DESIGN.md` §4 « system-native affordances on iOS/Android » lu comme une retenue, pas comme un ancrage Material. Mais l'`InkWell` fournit aussi le focus clavier et sa traversée au Tab, ce qu'il ne faut pas perdre sur une app desktop. Le plan répond en construisant `Pressable` sur `FocusableActionDetector`, qui rend focus, survol et raccourci d'activation dans un seul widget.
  - **Ce qui est mis à l'échelle diffère entre les deux cartes, et c'est délibéré** — voir la décision ci-dessous.

## Design decision

Créer `Pressable`, le primitive d'interaction des cartes : il rend le focus, le survol et **l'état d'appui**, et met à l'échelle à `AppMotion.pressScale` (0,97) dès le `pointer-down`. Le faire consommer par `PosterCard` et `ContinueWatchingCard`, qui abandonnent leur `MouseRegion` et leur `InkWell` mais gardent chacune ses visuels de survol.

Corriger uniquement `PosterCard` laisserait la vignette la plus tapée de l'Accueil sans aucune réponse, à côté de cartes qui en ont une : deux traitements au lieu de trois, sur deux rows visibles simultanément (`home_screen.dart:221-245`). La décision porte donc sur les deux cartes.

**La mise à l'échelle s'applique à ce qui a été touché, pas à la carte entière par principe.** Cela produit deux traitements qui diffèrent — et la règle, elle, est la même :

- Sur `PosterCard`, l'affiche et les deux lignes de texte sont **une seule** cible de tap. `Pressable` enveloppe donc toute la `Column`.
- Sur `ContinueWatchingCard`, l'affiche reprend la lecture (`continue_watching_card.dart:97-98`) et le titre ouvre la fiche (`:157-158`) — **deux actions, deux destinations**. `Pressable` n'enveloppe donc que l'affiche. Mettre la carte entière à l'échelle ferait bouger le titre, qui est un autre contrôle : le skill §16 « Grouping & mapping » demande exactement l'inverse.

## Reuse

- Tokens : `AppMotion.pressScale` (0,97), `AppMotion.move` et `AppMotion.curve`, créés par le plan 04. L'échelle passe par `move` et non `fade` : c'est de la géométrie, donc annulée sous mouvement réduit (§14) — l'appui reste alors sans retour visuel de mouvement, ce qui est le comportement attendu.
- Primitive de plateforme : `FocusableActionDetector` (Flutter, `widgets/actions.dart`) — donne `onShowFocusHighlight`, `onShowHoverHighlight` et le mapping de l'`ActivateIntent` (Entrée / Espace) en un seul widget. **Aucune dépendance à ajouter.**
- Exemplaire de la structure de survol à conserver : `poster_card.dart:79-101` — `DecoratedBox` conditionnel en `Stack` par-dessus l'affiche. Les visuels ne changent pas, seule leur source d'état change.
- Animation : `AnimatedScale`, déjà utilisé dans le dépôt (`request_related_slider.dart:72`, `player_screen.dart:1399`). Il repart de la valeur affichée, donc un appui relâché à mi-course est repris en cours de route — ce que §3 demande. **Ne pas** introduire de `SpringSimulation` ici : un ressort ne sert qu'à transmettre une vélocité, et un appui n'en porte aucune.

**Ne pas** fusionner `PosterCard` et `ContinueWatchingCard` : elles diffèrent par leur nombre de cibles de tap, leur menu contextuel et leur barre de progression. La seule chose qu'elles partagent est le primitive d'interaction, qui est précisément ce que ce plan extrait.

## Changes

1. `app/lib/widgets/global/pressable.dart` — **nouveau fichier**
   - Change : créer `class Pressable extends StatefulWidget` avec `final Widget child`, `final VoidCallback? onTap`, `final ValueChanged<bool>? onHoverChanged`, `final ValueChanged<bool>? onFocusChanged`, `final MouseCursor cursor = SystemMouseCursors.click`. Il rend un `FocusableActionDetector` (branché sur `onShowHoverHighlight` → `onHoverChanged`, `onShowFocusHighlight` → `onFocusChanged`, et un `ActivateIntent` mappé sur `onTap`) enveloppant un `GestureDetector` :
     - `onTapDown` → `setState(_pressed = true)`
     - `onTapUp` et `onTapCancel` → `setState(_pressed = false)`
     - `onTap` → `widget.onTap`
     - `behavior: HitTestBehavior.opaque`
   - …dont l'enfant est `AnimatedScale(scale: _pressed ? AppMotion.pressScale : 1.0, duration: AppMotion.move(context), curve: AppMotion.curve, child: child)`.
   - Utiliser `onTapDown` / `onTapCancel` du recognizer de tap, **et non un `Listener` sur les événements bruts** : dans une row qui défile, le recognizer de tap perd l'arène au profit du scrollable dès que l'utilisateur fait glisser, ce qui déclenche `onTapCancel` et rend l'échelle. Un `Listener` ne le verrait pas et la carte resterait rétrécie pendant tout le défilement. C'est aussi ce que demande §10 (« allow cancel-by-dragging-away »).
   - Documenter en commentaire de doc : pourquoi il n'y a pas d'ondulation (§1 — le retour est à l'appui, instantané), et pourquoi le focus passe par `FocusableActionDetector` (la traversée au Tab de l'`InkWell` remplacé doit survivre).
   - Preserve : sans objet, fichier neuf.
   - Verify : au clavier, Tab atteint le widget et Entrée l'active ; à la souris, `onHoverChanged` suit l'entrée et la sortie ; au doigt, l'appui rétrécit et le relâchement rend.

2. `app/lib/widgets/global/poster_card.dart`
   - Change : remplacer le couple `MouseRegion` + `InkWell` (lignes 62-67) par un unique `Pressable(onTap: widget.onTap, onHoverChanged: (v) => setState(() => _hovered = v), child: Column(...))`. Le champ `_hovered` et tout le bloc de survol (`:79-101`) restent inchangés — seule leur source d'état change. Ajouter l'import.
   - Preserve : le rayon 12 (`PosterCard.radius`), le `ClipRRect` de l'affiche, le liseré blanc 16 % au survol, le voile noir 22 % et l'icône play conditionnés par `showPlayOnHover`, les `overlays` positionnés, le `footerOverlay` clippé en bas (barre de progression), le traitement `dimmed`, les placeholders de chargement et d'erreur, la variante `compact` (tailles 13/11 et espacements 7/3), et les commentaires de doc de la classe — ils expliquent que `posterUrl` sert d'identité de cache, ce qui doit voyager avec le fichier.
   - Verify : sur les grilles Films et Séries, appuyer sans relâcher rétrécit la carte ; relâcher la rend et ouvre la fiche ; commencer un appui puis faire glisser hors de la carte la rend **sans** ouvrir la fiche. Plus aucune ondulation sous le titre.

3. `app/lib/widgets/global/continue_watching_card.dart`
   - Change : remplacer le `MouseRegion` externe (ligne 85) — qui n'alimente que `_hovered` — par le `onHoverChanged` d'un `Pressable`, et remplacer le `GestureDetector(onTap: widget.onTap)` des lignes 97-98 par ce `Pressable`, qui n'enveloppe que le `SizedBox(width, height)` de l'affiche (`:99-151`). Ajouter l'import.
   - Preserve, et c'est le point délicat de ce plan :
     - le `GestureDetector` **externe** (ligne 88) qui porte `onSecondaryTapDown` et `onLongPressStart` (`:89-90`) reste où il est, autour de toute la carte — le menu contextuel « Marquer comme vu / Supprimer de Reprendre » doit rester accessible au clic droit **et** à l'appui long, y compris depuis le titre ;
     - vérifier que l'appui long continue de fonctionner : le `Pressable` interne réclame le tap, le `GestureDetector` externe l'appui long ; les deux recognizers coexistent dans l'arène, mais l'appui long doit gagner sur un appui maintenu. Si un conflit apparaît, passer `onLongPress` au `Pressable` plutôt que d'imbriquer deux détecteurs ;
     - le `MouseRegion` du **titre** (`:153-156`) et son `GestureDetector(onTap: widget.onTitleTap)` (`:157-158`) restent intacts et **sans** échelle : c'est un lien texte vers une autre destination, et une mise à l'échelle de texte à 13 px n'apporte rien ;
     - le voile de survol noir 40 % avec liseré blanc 16 % et l'icône `play_circle_fill_rounded` 52 px (`:114-131`), la `LinearProgressIndicator` 4 px clippée en bas de l'affiche (`:132-147`), les constantes `cardWidth` / `posterHeight` / `rowHeight`, et le `_detailLine()`.
   - Verify : sur l'Accueil, appuyer sur une vignette « Reprendre » la rétrécit et la lecture reprend au relâchement ; le titre reste cliquable et ouvre la fiche ; le clic droit et l'appui long ouvrent toujours le menu contextuel ; le titre ne bouge pas quand on appuie sur l'affiche.

## Scope

- Inherit : via `PosterCard` — les grilles Films, Séries, résultats de recherche, Demandes, les écrans Collection et Personne, et les rows de l'Accueil. Via `ContinueWatchingCard` — la row « Reprendre la lecture ». Sur les quatre plateformes.
- Verify :
  - `PosterCard` est rendu à 118 px de large en compact et 150 px sinon (`AppLayout.mediaRowCardWidth`, `responsive.dart:58-59`). Confirmer qu'à 118 px, une échelle de 0,97 reste perceptible sans paraître un tremblement.
  - `MediaRow` monte les cartes dans une `ListView` horizontale (`media_row.dart:82-107`) et les grilles dans des `SliverGrid` verticaux : tester l'annulation par défilement dans les deux axes.
  - `RequestMediaCard` et `CatalogPosterCard` héritent sans modification puisqu'ils délèguent à `PosterCard`. Vérifier qu'ils n'ajoutent pas eux-mêmes un `InkWell` par-dessus, ce qui doublerait les recognizers.
- Exclude : `_RelatedCard` (`request_related_slider.dart`) — son `AnimatedScale` de survol à 1,03 / 160 ms est hors plage et hors token, mais c'est un bandeau secondaire dans une fiche de demande et l'aligner demande de trancher entre survol et appui, ce que ce plan ne fait que pour les cartes principales. Exclure aussi `GlassNavTab` et `GlassIconButton` (chrome, pas contenu), `EpisodeTile`, les cibles tactiles de 44 px (finding séparé), les `Hero` de navigation, et toute modification des visuels de survol existants.

## Validation

- Product : depuis l'Accueil, reprendre une lecture depuis « Reprendre », ouvrir une fiche depuis « Films récents », ouvrir le menu contextuel d'une vignette « Reprendre » au clic droit puis à l'appui long, ouvrir une fiche depuis la grille Films, depuis la grille Demandes, depuis une collection et depuis une fiche de personne. Toutes ces routes doivent s'ouvrir comme avant.
- Interface : aux largeurs 375, 600, 899, 901 et 1440 px. Tester au doigt sur Android **et** à la souris sur desktop — c'est un plan dont l'essentiel du bénéfice n'est visible qu'au tactile. Tester avec une affiche manquante (placeholder) et une carte `dimmed`.
- Accessibilité : au clavier, Tab doit atteindre les cartes d'une grille et Entrée les ouvrir — c'est la capacité que le remplacement de l'`InkWell` risque de perdre, donc c'est le test qui compte le plus. Avec « Réduire les animations » activé, l'appui ne doit produire aucune mise à l'échelle et l'ouverture doit rester identique.
- System : après ce plan, aucune carte de contenu ne peint d'ondulation Material, et l'état d'appui, de survol et de focus des cartes est décidé dans un seul fichier.
- Repository :
  - `grep -n "InkWell" app/lib/widgets/global/poster_card.dart` → aucun résultat.
  - `grep -n "MouseRegion" app/lib/widgets/global/poster_card.dart` → aucun résultat.
  - `grep -rn "pressScale" app/lib/` → deux résultats : la déclaration dans `app_motion.dart`, l'usage dans `pressable.dart`.
  - `cd app && flutter analyze lib/widgets/global/pressable.dart lib/widgets/global/poster_card.dart lib/widgets/global/continue_watching_card.dart` → `No issues found`.

## Stop conditions

- Stop si l'appui long de `ContinueWatchingCard` cesse de fonctionner une fois le `Pressable` imbriqué, et que le déplacer sur le `Pressable` ne le rétablit pas : signaler plutôt que de supprimer le menu contextuel ou de laisser la carte sans réponse à l'appui.
- Stop si le retrait de l'`InkWell` casse la traversée au Tab sur les grilles malgré `FocusableActionDetector` : le menu contextuel et le clavier sont des capacités existantes, aucune n'est négociable contre un retour d'appui.
- Stop si `AnimatedScale` provoque un recadrage ou un clip inattendu dans les cellules de `SliverGrid` : une échelle inférieure à 1 ne devrait pas déborder, mais le signaler si c'est le cas plutôt que de compenser par des marges.
- Stop si le périmètre tend à s'étendre aux boutons de chrome (`GlassIconButton`, `GlassNavTab`) : ce plan porte sur les cartes de contenu. Le chrome a ses propres contraintes de cible tactile, traitées ailleurs.

## Design documentation

- Après acceptation et validation : ajouter à `PROJECT_DESIGN.md` §8 « Media cards », à côté de la ligne « Hover desktop », une ligne **« Press (toutes plateformes) : scale 0.97, `AppMotion.move` »**, et préciser que l'état d'appui, de survol et de focus des cartes est porté par `app/lib/widgets/global/pressable.dart`. Noter dans §10 que les cartes de contenu ne peignent plus d'ondulation Material. Ne pas modifier `design.md`, qui est le brief incumbent superseded.
