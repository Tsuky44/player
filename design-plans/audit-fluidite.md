# Audit fluidité — Onyx (app Flutter : macOS, Windows, Android, web)

Écrit contre `c549dde` (2026-08-15). Grille de lecture : le skill **apple-design** (WWDC *Designing Fluid Interfaces*, *The Details of UI Typography*, *Principles of Great Design*), traduit du web vers Flutter.

Cet audit est **complémentaire** de [audit-ui.md](audit-ui.md) (2026-07-18), qui portait sur les tokens statiques — couleur, rayon, palette parallèle. Ces trois findings-là sont corrigés (plus aucun `#E50914`, plus aucun hex Tailwind dans `screens/requests/`, `ContinueWatchingCard` aligné). Le présent audit porte sur ce que le précédent avait explicitement exclu : **le mouvement, la réponse à l'entrée, la matière et la typographie**.

## Périmètre et sources

- **Surface auditée** : `app/lib` (138 fichiers Dart, 38 303 lignes) — `main.dart` → `MainShell` → 4 onglets → fiches détail → `PlayerScreen` et ses trois chromes.
- **Sources de design** : `PROJECT_DESIGN.md` (gouvernant), `design.md` (prose), `app/lib/theme/` (tokens exécutés), et le skill apple-design comme référentiel de mouvement — aucun équivalent n'existe aujourd'hui dans le dépôt.
- **Constat structurant** : le dépôt n'a **aucun owner de mouvement**. `app_theme.dart` définit couleur, forme et texte ; il ne définit ni durée, ni courbe, ni ressort. Résultat mesuré sur l'ensemble de `app/lib` :

| Mesure | Valeur | Ce que dit le skill |
| --- | --- | --- |
| Courbes distinctes utilisées | 5 (`easeOut` ×24, `easeOutCubic` ×12, `easeIn` ×2, `easeInOut` ×1, `easeInOutCubic` ×1) | §4 — le ressort, pas la durée fixe, pour tout ce qui est touchable |
| Simulations à ressort (`SpringSimulation`) | **0** | §3, §4, §5 |
| Durées distinctes codées en dur | 18 (80 → 1500 ms) | §4 — deux paramètres, pas dix-huit |
| Lectures de `MediaQuery.disableAnimations` | **0** | §14 — trois signaux à respecter |
| `Hero` (continuité de scène) | **0** | §7 — même chemin, origine ancrée |
| `TextStyle(` locaux vs lectures `textTheme.` | **298 vs 44** | §15 — échelle, pas valeurs au cas par cas |
| Valeurs de `letterSpacing` distinctes | 18 | §15 — le tracking dépend de la taille, il se dérive |
| Rayons `circular(n)` distincts | 21 | §16 Craft — « nothing is random » |
| `CircularProgressIndicator` vs squelettes | **36 vs 0** | §16 — exposer l'état sans casser la mise en page |

Tout ce qui suit découle de cette absence d'owner : chaque écran a inventé sa propre physique.

---

## Findings

### 1 — Le chrome par défaut du lecteur met 340 ms à apparaître et 0 ms à disparaître

**Confiance : élevée. Impact : le plus élevé de l'audit.**

`PlayerHUDOverlay` est le chrome que voit une installation neuve : `PlayerLayoutProvider` démarre sur `PlayerLayoutConfig.standard()` avec `_useModularLayout = false` (`providers/player_layout_provider.dart:17-18`), `standard()` ne pose pas de `fixedChrome` (`models/player_layout.dart:843`), donc `useDefaultHud` est vrai (`screens/player/player_screen.dart:1367-1369`) et c'est la branche `player_screen.dart:1602` qui est montée.

Ce chrome a deux défauts opposés sur le même geste :

- **Entrée** — `screens/player/widgets/player_hud_overlay.dart:242-244` : `.animate(interval: 40.ms).fadeIn(duration: 300.ms).slideY(begin: 0.05)`. L'utilisateur tape ou bouge la souris, et le panneau de contrôle finit d'arriver **340 ms plus tard** (300 ms + 40 ms de décalage sur le second enfant). Le skill §1 : « the moment lag appears, the feeling of directness falls off a cliff ».
- **Sortie** — `player_hud_overlay.dart:66` : `if (!visible) return const SizedBox.shrink();`. Coupe franche, zéro frame de transition.

Les deux se combinent en une violation de §7 (« if something disappears one way, we expect it to emerge from where it came ») : le HUD glisse vers le haut en fondu pour entrer, et se volatilise sur place pour sortir. Et comme l'animation d'entrée est un `flutter_animate` monté au build, elle n'est **pas interruptible** (§3) : re-taper pendant le fondu ne reprend pas la valeur à l'écran, ça rejoue depuis zéro.

**L'exemplaire correct existe déjà dans le dépôt** : `EmbyControlsLayer._fadeWithChrome` (`screens/player/widgets/emby/emby_controls_layer.dart:178-188`) enveloppe le chrome dans un `AnimatedOpacity` 200 ms `easeOut` **symétrique**, doublé d'un `IgnorePointer(ignoring: !visible)` pour qu'un contrôle invisible ne soit pas cliquable. `AnimatedOpacity` repart de la valeur courante à chaque changement de cible — c'est précisément le comportement interruptible que §3 demande.

**Correctif** : extraire ce wrapper en owner partagé (`widgets/global/player_chrome_fade.dart`) et le faire consommer par les trois chromes. Cible : ~180 ms `easeOut`, identique dans les deux sens, plus un `AnimatedSlide` de la même durée si le glissement est conservé — même chemin à l'aller et au retour.

---

### 2 — Trois chromes de lecteur, trois grammaires d'apparition différentes

**Confiance : élevée.**

Le même produit, sur le même écran, selon une préférence utilisateur :

| Chrome | Apparition | Disparition | Fichier |
| --- | --- | --- | --- |
| Emby | fondu 200 ms `easeOut` | fondu 200 ms `easeOut` | `emby_controls_layer.dart:183-186` |
| HUD par défaut | fondu + glissement 300 ms, décalé 40 ms | **instantanée** | `player_hud_overlay.dart:242-244` / `:66` |
| Modulaire | **instantanée** | **instantanée** | `modular_controls_layer.dart:165` |

`modular_controls_layer.dart:165` est le même `if (!visible) return const SizedBox.shrink();` que le HUD, sans même le fondu d'entrée : les contrôles clignotent à l'apparition comme à la disparition.

Le skill §16 Familiarité : « things that look the same must behave the same ». Trois chromes qui se distinguent par leur *disposition* ne doivent pas se distinguer par leur *physique*. Le correctif du finding 1 résout les trois d'un geste.

---

### 3 — Deux scrubbers sur trois affichent la position du décodeur, pas celle du doigt

**Confiance : élevée.**

§2 est la règle la plus littérale du skill : « touch and content should move together ». Pendant un drag, la barre doit peindre **où est le doigt**, pas où en est le lecteur.

- **Correct** — `EmbyProgressBar` tient un `_dragFraction` local, peint `_shownFraction => _dragFraction ?? widget.progress` et ne commet le seek qu'au relâchement (`screens/player/widgets/emby/emby_progress_bar.dart:56-59`, `:96-104`). La barre est collée au doigt, le seek coûteux arrive une fois. C'est l'exemplaire à généraliser.
- **Incorrect** — `_SeekableBar` (`screens/player/widgets/modular_controls_layer.dart:393-397`) n'a aucun état local : il émet `onSeekFraction` à chaque `onHorizontalDragUpdate`, et la barre qu'il enveloppe est peinte à partir du `progress` que `player_screen.dart:1561` lui passe depuis le contrôleur. Le rendu suit donc la latence de seek de mpv/HLS, pas le pointeur.
- **Incorrect, même cause** — `_TimelineSeekable` (`widgets/global/control_chrome.dart:1737-1765`), qui met en plus le lecteur en pause au `dragStart` et le relance au `dragEnd` : chaque micro-drag provoque un aller-retour pause/play.

**Correctif** : hisser le patron d'`EmbyProgressBar` dans un `ScrubState` partagé (fraction locale pendant le drag, commit au relâchement, `onScrubbingChanged` pour tenir le chrome ouvert — ce dernier est déjà câblé côté `player_screen.dart:1508-1516`).

**Bonus §6, pas encore présent nulle part** : au relâchement d'un flick sur la barre, projeter le point d'arrivée au lieu de s'arrêter net —
`projected = current + (v/1000) * d / (1 - d)` avec `d ≈ 0.998`. Sur une timeline avec chapitres (`chapterMarks` existe déjà, `emby_progress_bar.dart:157`), c'est ce qui transforme un flick en « saut au chapitre » naturel.

---

### 4 — Aucune rétroaction au pointer-down : les cartes ne réagissent qu'au survol

**Confiance : élevée. Impact : touche toutes les surfaces tactiles.**

§1 : « respond on pointer-down, not on release ». §10 : « highlight on touch-down (instant), commit on touch-up ».

- `PosterCard` (`widgets/global/poster_card.dart:62-101`) : `MouseRegion` + `InkWell`. Le liseré blanc 16 % et l'icône play n'existent **que sous `_hovered`** — c'est-à-dire uniquement au pointeur. Sur Android et sur tablette, la seule réponse à l'appui est l'ondulation Material par défaut, et comme l'`InkWell` enveloppe toute la `Column` (poster + titre + sous-titre, `poster_card.dart:65-68`), elle se peint aussi sous le texte.
- `ContinueWatchingCard` (`widgets/global/continue_watching_card.dart:88-97`) : `GestureDetector` nu. **Aucune** rétroaction à l'appui, ni ondulation, ni échelle, ni voile — la première ligne de l'Accueil, celle sur laquelle on tape le plus, ne répond pas avant que la route ne pousse.
- `_RelatedCard` (`screens/requests/widgets/request_related_slider.dart:70-73`) est le seul à faire quelque chose de proche : `AnimatedScale` 1.03 à 160 ms — mais au survol, pas à l'appui, et cette valeur n'existe nulle part ailleurs.

**Correctif** : un owner `PressableCard` — `onTapDown` → `scale: 0.97` en ~100 ms, relâchement → retour ressort critique (amortissement 1.0, réponse 0.3), plus l'état de survol existant sur desktop. Consommé par `PosterCard`, `ContinueWatchingCard`, `_RelatedCard`, `GlassNavTab`, `GlassIconButton`. C'est le finding le moins cher de l'audit et celui qui se sent immédiatement, sur chaque écran.

---

### 5 — Aucune continuité spatiale entre une affiche et sa fiche, et la grammaire de navigation change selon l'OS

**Confiance : élevée.**

`Hero` n'apparaît nulle part dans `app/lib` (0 occurrence ; les correspondances `DetailHero`/`HeroBanner` sont des noms de classes maison). Taper une affiche dans la grille détruit cette affiche et pousse un écran entier qui en reconstruit une autre. §7 : « anchor interactions to their source » — le lien entre l'objet touché et l'écran obtenu n'est jamais montré.

Second défaut, même famille : `app_theme.dart` ne pose aucun `pageTransitionsTheme`. Flutter applique donc sa table par défaut — glissement Cupertino sur macOS/iOS, `ZoomPageTransitionsBuilder` sur Windows/Linux. **Le build web hérite de la grammaire de l'OS hôte** : la même URL, ouverte sous macOS et sous Windows, ne navigue pas de la même façon.

**Correctif** :
1. `Hero(tag: 'poster-${media.id}')` autour de l'image dans `PosterCard`/`MediaPoster` et autour de l'affiche du `DetailBackdropHeader` — les quatre écrans de catalogue passent par ces deux owners, donc c'est deux points de couture, pas quinze.
2. Poser un `pageTransitionsTheme` explicite dans `AppTheme.dark` avec le même builder pour toutes les cibles, pour que le chemin d'entrée et de sortie soit le même partout.

---

### 6 — Le carrousel d'accueil bouge tout seul, ne peut pas être arrêté au doigt, et ignore « Réduire les animations »

**Confiance : élevée.**

`HeroCarousel` (`widgets/global/hero_carousel.dart:24`, `:61-69`) fait avancer un fond plein écran toutes les **7 secondes** avec une transition de **900 ms** en `easeInOutCubic`. C'est une oscillation en boucle à ~0,14 Hz sur la plus grande surface de l'application — exactement la famille que §14 demande d'éviter (« slow looping oscillations near 0.2 Hz », « avoid full-viewport moving backgrounds »).

Deux aggravations :

- **La pause n'existe qu'au survol** (`hero_carousel.dart:87-95`). Sur Android, sur tablette, et sur tout écran tactile, il n'y a pas de survol : le mouvement est **inarrêtable**. §16 Agency : « keep people in control ».
- **`MediaQuery.disableAnimations` n'est lu nulle part dans l'application** (0 occurrence sur 138 fichiers). « Réduire les animations » d'iOS/macOS et « Supprimer les animations » d'Android sont sans effet — sur ce carrousel comme sur le reste.

**Correctif** :
1. Lire `MediaQuery.disableAnimationsOf(context)` dans `_scheduleAutoAdvance` : si vrai, pas d'auto-avance du tout, et fondu croisé au lieu du glissement quand l'utilisateur navigue lui-même.
2. Suspendre aussi sur `onPointerDown` et pendant le scroll, pas seulement sur `onEnter`.
3. Porter le même garde-fou dans l'owner de mouvement pour que chaque transition de l'app le respecte par construction.

---

### 7 — Cinq recettes de verre non hiérarchisées, et la plus grande surface est la plus légère

**Confiance : élevée.**

§12 : le poids de la matière encode la hiérarchie, les grandes surfaces doivent se lire plus épaisses, et **on n'empile jamais une surface translucide claire sur une autre**. Le dépôt a cinq recettes indépendantes, aucune dérivée d'un token :

| Surface | Flou | Remplissage | Fichier |
| --- | --- | --- | --- |
| `GlassHeaderStrip` (bandeau desktop) | 30 | noir 0,35 → 0,12 | `widgets/global/glass_chrome.dart:15-31` |
| `GlassSurface` (popovers) | 24 | noir 0,45 | `widgets/global/glass_chrome.dart:54-64` |
| `_MobileBottomNav` (nav mobile) | 20 | **blanc 0,05** | `screens/shell/main_shell.dart:214-222` |
| Panneau HUD lecteur | 24 | `#1A1A1A` 0,6 | `player_hud_overlay.dart:100-106` |
| `LiquidGlassPanel` | +6 sur la base, saturation 1,55, luminosité 1,05 | dégradé blanc | `widgets/global/liquid_glass_panel.dart:70-128` |

La navigation mobile — pleine largeur, structurelle, permanente — est la **plus légère et la moins floue** des cinq, alors que §12 la classe parmi les matières lourdes (« darker/heavier materials separate structural regions »). Les popovers, plus petits et plus éphémères, sont plus opaques qu'elle.

Autre point §12 non traité : « scroll edge effects, not hard dividers ». Le bandeau desktop se sépare du contenu par un trait blanc 8 % (`glass_chrome.dart:28-30`) et la nav mobile par le même trait (`main_shell.dart:220-221`), là où le skill demande un dégradé de flou à la rencontre du contenu.

**Correctif** : un owner `AppGlass` à trois niveaux nommés — `chrome` (structurel, lourd, flou fort, ombre profonde), `panel` (feuilles/dialogues, intermédiaire), `popover` (menus, léger) — qui fixe flou, remplissage, liseré et ombre par niveau. `LiquidGlassPanel` devient une variante décorative de `panel`, pas une sixième recette.

**Note perte de performance** : cinq `BackdropFilter` empilables, dont un composé avec une `ColorFilter.matrix` (`liquid_glass_panel.dart:72-77`), sur des écrans qui lisent en parallèle une texture vidéo mpv. §14 demande un équivalent de `prefers-reduced-transparency` — Flutter ne l'expose pas, donc le correctif honnête est un réglage **« Réduire la transparence »** dans `settings_screen.dart` qui bascule les trois niveaux sur des remplissages opaques issus de `AppColors`. Gain double : accessibilité et budget GPU.

---

### 8 — La typographie est décidée 298 fois localement au lieu d'être dérivée d'une échelle

**Confiance : élevée.**

298 `TextStyle(` construits sur place contre 44 lectures de `textTheme.` — soit ~87 % de la typographie de l'app définie hors du thème. Conséquences mesurables : **18 tailles distinctes** (de 8 à 42, dont `11.5` et `12.5`) et **18 valeurs de `letterSpacing`** allant de `-0.8` à `6`, posées au cas par cas.

§15 dit que le tracking est une fonction de la taille — négatif quand le texte grandit, légèrement positif quand il rétrécit — et donc qu'il se **dérive**, il ne se choisit pas par site d'appel. Aujourd'hui `-0.2` est appliqué indifféremment à du 11 et du 20 ; `letterSpacing: 6` et `4` cohabitent avec `-0.8` sans règle lisible. Il n'y a aucune façon de vérifier qu'un écran est cohérent avec un autre : il faudrait comparer 298 déclarations.

§15 demande aussi de **scaler la mise en page avec le texte** (Dynamic Type). L'app ne lit jamais `MediaQuery.textScalerOf`, et les hauteurs sont fixes : `ContinueWatchingCard.rowHeight = posterHeight + 6 + 40` (`continue_watching_card.dart:11`) réserve exactement 40 px pour deux lignes de texte — au premier cran d'agrandissement système, ça déborde.

**Correctif** : compléter `AppTheme.dark` avec l'échelle complète (`displayLarge` → `labelSmall`), tracking et interlignage dérivés de la taille dans un seul helper, et remplacer les `TextStyle(` locaux par des `Theme.of(context).textTheme.x.copyWith(...)`. C'est mécanique et se fait par lots d'écrans. Le frontmatter YAML de `design.md` contient déjà une échelle nommée (`display-lg`, `headline-lg`, `body-md`, `label-md`, `caption-sm`) qu'aucun code Dart ne lit — c'est le point de départ, à réconcilier d'abord avec `PROJECT_DESIGN.md`.

---

### 9 — 36 spinners, 0 squelette : chaque chargement déplace la mise en page

**Confiance : moyenne (dépend de l'écran).**

36 `CircularProgressIndicator` répartis sur 27 fichiers, aucun placeholder structurel. Sur une grille d'affiches, la séquence est : spinner centré → grille pleine, donc un saut de mise en page à chaque chargement. §16 Craft : « jittery scroll, misaligned icons, and layouts that break on rotation read as carelessness ».

`PosterCard` fait déjà la moitié du travail au bon endroit — `placeholder: ColoredBox(color: AppColors.surfaceElevated)` (`poster_card.dart:157`) tient la forme de l'affiche pendant le chargement de l'image. Il manque le même raisonnement un cran au-dessus : une grille de N `PosterCard` fantômes pendant que la requête catalogue est en vol, plutôt qu'un spinner.

---

### 10 — `AppLayout.minTouchTarget` est défini et n'est consommé nulle part

**Confiance : élevée. Faible effort.**

`utils/responsive.dart:61-62` déclare `minTouchTarget` (48 en compact, 44 sinon) — **zéro consommateur** dans tout `app/lib`. Pendant ce temps `GlassIconButton` a un côté par défaut de 32 (`widgets/global/glass_chrome.dart:266`), sous le seuil que le dépôt s'est lui-même fixé.

L'exemplaire correct est, là encore, dans le chrome Emby : `EmbyChromeMetrics` réserve `hitSize = 40` en compact et `44` en desktop autour d'une barre de 4 px (`screens/player/widgets/emby/emby_chrome_theme.dart:92`, `:106`), avec le commentaire qui explique pourquoi (`emby_progress_bar.dart:72-74`). C'est exactement l'hystérésis de §10.

**Correctif** : faire consommer `minTouchTarget` par `GlassIconButton`, `_TimelineBarIcon` et `_EmbyTimelineIcon` via un `ConstrainedBox` — la cible grandit, le visuel ne bouge pas.

---

## Improve first

**Findings 1, 2 et 4, dans cet ordre.**

> **Plans écrits** : [04 — Owner de mouvement](04-owner-de-mouvement.md) (prérequis), [05 — Fondu de chrome lecteur](05-fondu-chrome-lecteur.md) (findings 1 et 2), [06 — Rétroaction à l'appui](06-retroaction-appui.md) (finding 4).

Ce sont les trois qui partagent une seule cause — l'absence d'owner de mouvement — et les trois qui se sentent à chaque interaction plutôt qu'à chaque écran. Ensemble ils demandent trois nouveaux fichiers et aucune refonte :

1. `theme/app_motion.dart` — trois durées (180 / 200 / 260 ms), une courbe (`easeOut`), une échelle d'appui (0,97), et les deux helpers `fade` / `move` qui portent §14. Toutes les durées tiennent dans la plage 180–280 ms que `PROJECT_DESIGN.md` §10 impose déjà — l'owner ne fait que nommer des valeurs que le dépôt applique déjà par endroits. Le garde-fou `disableAnimations` vit dans ce fichier, pas dans les appelants : `fade` conserve l'opacité (non vestibulaire), `move` annule la géométrie.

   **Pas de ressort pour l'instant, délibérément.** Un ressort ne paie que là où un geste porte une vélocité à transmettre (§5) — relâchement de drag, flick. L'app n'en a aucun aujourd'hui, et les animations implicites de Flutter repartent déjà de la valeur affichée, ce qui suffit à les rendre interruptibles (§3). Le premier vrai candidat est le finding 3, quand le scrubber accrochera les chapitres au flick.
2. `widgets/global/player_chrome_fade.dart` — le wrapper d'`emby_controls_layer.dart:180-190` extrait et consommé par les trois chromes (findings 1 et 2).
3. `widgets/global/pressable.dart` — appui, survol et focus dans un seul primitive : échelle 0,97 au `onTapDown`, retour au relâchement ou à l'annulation par glissement (finding 4).

Les findings 5 à 10 sont indépendants entre eux et peuvent suivre dans n'importe quel ordre. Les 7 et 8 sont les plus volumineux et se traitent par lots d'écrans.

## Observations écartées

Relevées, mais qui n'ont pas passé le gate de preuve — notées pour transparence, pas comme findings :

- **`withOpacity` déprécié** — 100 appels restants contre 274 `withValues`. Dette technique réelle (perte de précision en espace linéaire), mais aucun effet visible : ce n'est pas un défaut d'interface.
- **`setState` sur tout l'arbre du lecteur** — `player_screen.dart:593`, `:619` reconstruisent l'écran entier à chaque bascule du chrome. Le commentaire ligne 601 montre que c'est un choix conscient. §11 recommande de n'animer que les propriétés compositables ; sans mesure de frame ici, je ne peux pas affirmer que ça coûte des images.
- **Pilule pleine sur les onglets de nav desktop** (`glass_chrome.dart:236`) — déjà relevé et écarté par [audit-ui.md](audit-ui.md) pour la même raison : le contrat propose deux corrections possibles (soulignement *ou* point), la preuve ne détermine pas laquelle.
- **Le frontmatter de `design.md` contredit toujours sa propre prose** — `surface: #121414`, `primary: #c9c6c5`, police `Geist` en tête ; charcoal `#0A0A0A`, accent `#0A84FF`, Manrope dans le texte. Aucun code Dart ne lit ce fichier. Risque de documentation, déjà signalé en 2026-07-18, toujours ouvert — et il devient bloquant dès qu'on attaque le finding 8, qui a besoin d'une échelle typographique de référence non ambiguë.
- **Retour haptique et sonore** (§13) — totalement absent (`HapticFeedback` : 0 occurrence). Une omission, pas un défaut : §13 dit de réserver le haptique aux moments qui le méritent, et rien dans le produit ne l'exige aujourd'hui. À rouvrir si le finding 3 amène un accrochage aux chapitres, qui est précisément le genre de « snap » que §13 justifie.
- **Contraste et sémantique** — `Semantics`/`tooltip` présents sur 14 fichiers sur 138. Hors périmètre de cet audit (mouvement et matière) ; mérite sa propre passe avec le skill `fixing-accessibility`.
