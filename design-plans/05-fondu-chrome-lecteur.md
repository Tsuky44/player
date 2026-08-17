# Les trois chromes du lecteur apparaissent et disparaissent par le même fondu

Written against: `c549dde` (2026-08-15)

Dépend du plan [04 — Owner de mouvement](04-owner-de-mouvement.md), qui doit être exécuté avant.

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web ; ce plan vaut pour les quatre cibles. Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine.

`PlayerScreen` (`app/lib/screens/player/player_screen.dart`) monte **un** chrome parmi trois, choisi par les préférences de layout de l'utilisateur (`player_screen.dart:1367-1369`) :

- `fixedChrome != null` → `EmbyControlsLayer` (`player_screen.dart:1497`)
- sinon `useModularLayout` → `ModularControlsLayer` (`player_screen.dart:1556`) — le layout éditable par le Player Studio
- sinon → `PlayerHUDOverlay` (`player_screen.dart:1602`) — **le défaut d'une installation neuve** : `PlayerLayoutProvider` démarre sur `PlayerLayoutConfig.standard()` avec `_useModularLayout = false` (`providers/player_layout_provider.dart:17-18`) et `standard()` ne pose pas de `fixedChrome` (`models/player_layout.dart:843`).

Les trois reçoivent le même booléen `visible: _controlsVisible` (`player_screen.dart:1498`, `:1558`, `:1603`), piloté par `_showControlsTransient()` / `_hideControlsWithDelay()` (`player_screen.dart:615-622`, `:585-596`, minuterie de 4 s).

## Evidence chain

- Surface : le chrome du lecteur sur les trois layouts, c'est-à-dire chaque lecture de chaque média sur chaque plateforme.
- Problème : le même booléen produit trois comportements différents, et deux des trois sont hors contrat.

  | Chrome | Apparition | Disparition | Preuve |
  | --- | --- | --- | --- |
  | Emby | fondu 200 ms `easeOut` | fondu 200 ms `easeOut` | `emby_controls_layer.dart:180-190` |
  | HUD (défaut) | fondu **300 ms** + glissement, décalé 40 ms | **instantanée** | `player_hud_overlay.dart:242-244` / `:66` |
  | Modulaire | **instantanée** | **instantanée** | `modular_controls_layer.dart:165` |

  - `player_hud_overlay.dart:242-244` : `.animate(interval: 40.ms).fadeIn(duration: 300.ms, curve: Curves.easeOut).slideY(begin: 0.05, end: 0, duration: 300.ms, ...)`. Deux enfants dans la `Column` (barre du haut, panneau du bas) et un `interval` de 40 ms : le panneau de contrôle finit d'arriver **340 ms** après le geste qui l'a demandé.
  - `player_hud_overlay.dart:66` et `modular_controls_layer.dart:165` : `if (!visible) return const SizedBox.shrink();` — le sous-arbre est démonté, donc zéro frame de transition à la sortie.
  - L'animation d'entrée du HUD est un `flutter_animate` déclenché au montage : elle n'est pas interruptible. Re-solliciter le chrome pendant le fondu ne reprend pas la valeur affichée, elle rejoue depuis zéro.
- Design evidence :
  - `PROJECT_DESIGN.md` §10 (ligne 128) : « Motion: **180–280ms** ease-out ; hero crossfade ; **control fade** ». Le fondu de chrome est nommé explicitement dans le brief ; 300 ms est hors plage, 0 ms aussi.
  - `PROJECT_DESIGN.md` §2 (ligne 20), patterns à préserver : « player auto-hide HUD » — le comportement d'auto-masquage reste, seule sa physique change.
  - `PROJECT_DESIGN.md` §3 (ligne 33) : « player HUD qui disparaît » ; §11 Do : « Align shell + player + login on same tokens ».
  - Skill apple-design §1 (« be vigilant about every latency ; anything on the input path that isn't essential is a regression »), §3 (« always animate from the presentation value ; never lock out input during a transition »), §7 (« if something disappears one way, we expect it to emerge from where it came »), §16 Familiarité (« things that look the same must behave the same »).
- Owner : n'existe pas comme owner partagé, mais **l'implémentation correcte existe déjà** — `EmbyControlsLayer._fadeWithChrome` (`emby_controls_layer.dart:180-190`) : un `IgnorePointer(ignoring: !visible)` autour d'un `AnimatedOpacity(opacity: visible ? 1 : 0, duration: 200 ms, curve: easeOut)`. `AnimatedOpacity` repart de la valeur affichée à chaque changement de cible, donc il est interruptible par construction — exactement ce que §3 demande. Ce plan l'extrait.
- Scope and affected surfaces : `app/lib/widgets/global/player_chrome_fade.dart` (nouveau), `app/lib/screens/player/widgets/emby/emby_controls_layer.dart`, `app/lib/screens/player/widgets/player_hud_overlay.dart`, `app/lib/screens/player/widgets/modular_controls_layer.dart`.
- Uncertainty :
  - Garder le sous-arbre monté à opacité 0 au lieu de le démonter a un coût de build et de layout. Le coût de **peinture** est nul : `RenderAnimatedOpacity` court-circuite la peinture de ses enfants à alpha 0, donc les `BackdropFilter` du chrome (flou 24 dans le panneau HUD, `player_hud_overlay.dart:101`) ne coûtent rien tant qu'il est invisible. Le coût de build est déjà borné par ailleurs : `_refreshPositionUi` est fermé quand le chrome est caché (`player_screen.dart:421`, `_needsPositionUiRefresh() => _showControls || _showEpisodesPanel`), donc la fréquence des `setState` ne change pas.
  - Le HUD affiche-t-il une position périmée pendant le fondu d'entrée ? Non : `_showControlsTransient()` appelle `_refreshPositionUi(force: true)` dans le même `setState` que le passage à `visible: true` (`player_screen.dart:619-620`), donc la position est à jour dès la première frame du fondu.
  - Décision ouverte, tranchée ci-dessous : conserver ou non le `slideY` de 5 % du HUD.

## Design decision

Extraire le wrapper d'`EmbyControlsLayer` en owner partagé `PlayerChromeFade`, et le faire consommer par les trois chromes. Un fondu, une durée, une courbe, symétrique dans les deux sens.

Corriger seulement le HUD par défaut laisserait le modulaire en coupe franche : trois comportements remplacés par deux. La décision porte sur les trois consommateurs à la fois, ce qui est la seule façon de faire disparaître le motif parallèle au lieu de le réduire — et c'est aussi ce que demande §16 Familiarité, puisque ces trois layouts sont censés se distinguer par leur *disposition*, pas par leur *physique*.

**Le `slideY` du HUD est supprimé, pas migré.** Trois raisons : (a) il n'a pas d'équivalent à la sortie, donc le conserver demanderait d'inventer une sortie symétrique que ni le brief ni les deux autres chromes ne décrivent ; (b) le brief nomme un « control fade », pas un glissement ; (c) une translation est précisément ce que le mouvement réduit doit annuler, ce qui ferait diverger le HUD des deux autres chromes sous ce réglage. Le fondu seul est symétrique par construction : l'aller et le retour empruntent le même chemin, ce qu'exige §7.

## Reuse

- Exemplaire à extraire : `EmbyControlsLayer._fadeWithChrome` (`emby_controls_layer.dart:180-190`), y compris son commentaire de doc, qui explique pourquoi l'`IgnorePointer` est là (« takes it out of hit-testing while it is invisible, so a hidden control cannot be clicked »). Ce raisonnement doit voyager avec le code.
- Tokens : `AppMotion.standard` (200 ms) et `AppMotion.curve` (`easeOut`), créés par le plan 04. Le fondu passe par `AppMotion.fade` et **non** `AppMotion.move` : l'opacité n'est pas vestibulaire et le chrome doit rester compréhensible sous mouvement réduit (§14).
- Mécanisme de repli déjà en place : quand le chrome est rendu insensible au pointeur, les taps retombent sur la couche vidéo en dessous (`player_screen.dart:1460-1490`, trois zones `Expanded` qui appellent `_handleVideoTap`), qui rappelle `_showControlsTransient()`. C'est déjà ce qui se passe aujourd'hui quand le chrome renvoie `SizedBox.shrink()` — **le comportement de rappel du chrome est donc préservé sans câblage supplémentaire.**

**Ne pas** créer une classe de base commune aux trois chromes : ils diffèrent par leur disposition, leurs contrôles et leur configuration ; la seule chose qu'ils partagent est ce wrapper de visibilité. La répétition seule ne justifie pas une hiérarchie.

## Changes

1. `app/lib/widgets/global/player_chrome_fade.dart` — **nouveau fichier**
   - Change : créer `class PlayerChromeFade extends StatelessWidget` avec `final bool visible` et `final Widget child`, rendant :
     ```
     IgnorePointer(
       ignoring: !visible,
       child: AnimatedOpacity(
         opacity: visible ? 1 : 0,
         duration: AppMotion.fade(context),
         curve: AppMotion.curve,
         child: child,
       ),
     )
     ```
   - Reprendre en commentaire de doc les deux raisons : (a) l'`IgnorePointer` empêche de cliquer un contrôle invisible ; (b) l'`AnimatedOpacity` repart de la valeur affichée, donc une bascule pendant le fondu est reprise en cours de route au lieu d'être rejouée.
   - Preserve : sans objet, fichier neuf.
   - Verify : le widget compile isolément et n'importe que `material.dart` et `../../theme/app_motion.dart`.

2. `app/lib/screens/player/widgets/emby/emby_controls_layer.dart`
   - Change : supprimer la méthode `_fadeWithChrome` (lignes 178-190, commentaire de doc compris) et remplacer ses deux appels — `_fadeWithChrome(_buildTop(m, width))` (ligne 145) et `_fadeWithChrome(_buildBottom(m))` (ligne 168) — par `PlayerChromeFade(visible: visible, child: …)`. Ajouter l'import.
   - Preserve : **tout le reste à l'identique.** En particulier le bouton « passer l'intro », délibérément placé *hors* du fondu (`emby_controls_layer.dart:150-167` et son commentaire : une offre limitée dans le temps ne doit pas expirer derrière un chrome masqué), le `LayoutBuilder` qui dimensionne depuis ses propres contraintes pour que le Player Studio puisse rendre ce widget en aperçu réduit, les dégradés `topScrim`, et le `macOSWindowControlsTopInset`.
   - Verify : aucun changement visible sur ce chrome — c'est le contrôle de non-régression du plan. Si l'apparition ou la disparition change ici, l'extraction est fautive.

3. `app/lib/screens/player/widgets/player_hud_overlay.dart`
   - Change, en quatre points :
     - supprimer la garde `if (!visible) return const SizedBox.shrink();` (ligne 66) ;
     - envelopper le `Positioned.fill` retourné (ligne 81) dans `PlayerChromeFade(visible: visible, …)` — l'`IgnorePointer` doit donc englober le `GestureDetector(onTap: onToggleControls)` de la ligne 82, sinon le HUD invisible continuerait à intercepter les taps sur tout l'écran ;
     - supprimer la chaîne `.animate(interval: 40.ms).fadeIn(...).slideY(...)` (lignes 242-244) et rendre la `Column` directement ;
     - supprimer l'import `package:flutter_animate/flutter_animate.dart` (ligne 3), devenu inutilisé **dans ce fichier uniquement**.
   - Preserve : la disposition (barre du haut, `Spacer`, panneau de verre du bas), le panneau `BackdropFilter` flou 24 avec son liseré supérieur blanc 15 %, le `_DragProgressBar` et sa logique pause-au-premier-mouvement / reprise-au-relâchement (`:299-320`), l'`AnimatedSwitcher` 120 ms de l'icône play/pause (`:198-203`), les `_GlassIconButton`, les libellés de temps en `FontFeature.tabularFigures`, et le `clamp` défensif de `currentPos` avec son commentaire (`:74-79`).
   - Note : le `GestureDetector` de la ligne 82 avale aujourd'hui les taps sur tout l'écran quand le HUD est visible — le double-tap de seek des zones latérales ne fonctionne donc pas sous ce layout. C'est le comportement actuel ; **ne pas le changer ici**, il est hors périmètre.
   - Verify : bouger la souris ou taper pendant la lecture — le chrome arrive en 200 ms au lieu de 340, et repart en 200 ms au lieu de disparaître d'un coup. Taper à nouveau à mi-fondu : le chrome reprend depuis son opacité courante, sans saut.
   - Verify : quand le chrome est masqué, un tap sur le tiers gauche/droit de l'écran ramène bien le chrome (il traverse jusqu'à la couche vidéo).

4. `app/lib/screens/player/widgets/modular_controls_layer.dart`
   - Change : supprimer la garde `if (!visible) return const SizedBox.shrink();` (ligne 165) et envelopper le `Positioned.fill` retourné (ligne 169) dans `PlayerChromeFade(visible: visible, …)`. Ajouter l'import.
   - Preserve : le placement `Align` par pourcentages issu de la config du Studio, `_SeekableBar`, le traitement particulier des barres `timelineEmby` / `timelineGlassInline`, tous les `KeyedSubtree` porteurs de `settingsButtonKey` / `subtitlesButtonKey` / `mediaInfoButtonKey` / `timelineAnchorKey` — ces clés servent à ancrer les menus, les casser déplacerait les popovers du lecteur.
   - Verify : sous un layout modulaire, le chrome ne clignote plus ni à l'apparition ni à la disparition ; les menus réglages et sous-titres s'ouvrent toujours ancrés sur leur bouton.

## Scope

- Inherit : chaque lecture de chaque média, sur les quatre plateformes, quel que soit le layout choisi.
- Verify :
  - Le Player Studio rend `EmbyControlsLayer` en aperçu via `fixed_chrome_preview.dart:51`. Vérifier que l'aperçu passe `visible: true` et n'est donc pas affecté.
  - `TopRightControls` est monté séparément sous condition `_controlsVisible && useDefaultHud` (`player_screen.dart:1660-1661`) et **n'est pas** dans le sous-arbre du HUD : il gardera sa coupe franche après ce plan. C'est une incohérence résiduelle assumée — la traiter demanderait de toucher `player_screen.dart`, que ce plan n'ouvre pas. À noter pour un plan suivant.
  - Idem pour `SkipIntroButton` (`player_screen.dart:1672-1678`) et `NextEpisodeOverlay` (`player_screen.dart:1686-1693`), montés conditionnellement au niveau du `Stack` : hors périmètre, et pour `SkipIntroButton` c'est délibéré, au même titre que son équivalent Emby.
- Exclude : la logique de visibilité elle-même (minuterie de 4 s, `_handlePointerHover`, `_shouldHideCursor`), le masquage du curseur, le comportement des scrubbers (finding séparé), la disposition et le contenu des trois chromes, `player_screen.dart` — **aucune ligne de ce fichier ne doit changer**. Exclure aussi les quatre autres usages de `flutter_animate` (`player_episodes_panel.dart`, `player_info_sheet.dart`, `player_settings_sheet.dart`, `settings_menu.dart`) : le package reste au `pubspec.yaml`.

## Validation

- Product : lire un film et un épisode sous les trois layouts (Emby via les réglages du lecteur, modulaire via le Player Studio, défaut via `Réinitialiser` dans le Studio). Pour chacun : play/pause, seek à la barre, ouverture des menus audio/sous-titres, passage à l'épisode suivant, skip intro, retour arrière. Tout doit rester fonctionnel — le chrome ne change que de physique.
- Interface : aux largeurs 375, 600, 899, 901 et 1440 px, en fenêtré et en plein écran, sur macOS (encoches de fenêtre) et sur Android. Vérifier qu'aucun contrôle invisible n'est cliquable : chrome masqué, taper à l'emplacement du bouton play ne doit pas mettre en pause, mais ramener le chrome.
- System : après ce plan, `PlayerChromeFade` est le seul endroit de l'app qui décide comment un chrome de lecteur apparaît et disparaît, et il lit ses valeurs d'`AppMotion`.
- Accessibilité : activer « Réduire les animations » au niveau système — le fondu doit **rester** (l'opacité n'est pas vestibulaire, §14) ; aucun glissement ne doit subsister nulle part dans le chrome.
- Repository :
  - `grep -rn "if (!visible) return const SizedBox.shrink" app/lib/screens/player/` → aucun résultat.
  - `grep -n "flutter_animate" app/lib/screens/player/widgets/player_hud_overlay.dart` → aucun résultat.
  - `grep -rn "AnimatedOpacity" app/lib/screens/player/widgets/` → aucun résultat (le seul vit désormais dans `player_chrome_fade.dart`).
  - `git diff --stat app/lib/screens/player/player_screen.dart` → vide.
  - `cd app && flutter analyze lib/widgets/global/player_chrome_fade.dart lib/screens/player/widgets/player_hud_overlay.dart lib/screens/player/widgets/modular_controls_layer.dart lib/screens/player/widgets/emby/emby_controls_layer.dart` → `No issues found`.

## Stop conditions

- Stop si garder le HUD monté à opacité 0 fait chuter les images pendant la lecture : mesurer avant de conclure, et signaler le chiffre. Le repli n'est **pas** de réintroduire la coupe franche mais de piloter le montage par un `AnimationStatusListener` qui démonte après la fin du fondu de sortie — plus complexe, donc à ne faire que sur preuve.
- Stop si envelopper le `Positioned.fill` du HUD dans un `IgnorePointer` empêche de rappeler le chrome sur une plateforme : cela signifierait que la couche vidéo de `player_screen.dart:1460-1490` ne couvre pas toute la surface sur cette cible. Signaler plutôt que d'ajouter une seconde zone de tap.
- Stop si la suppression du `slideY` est refusée au revue : c'est la seule décision de goût du plan, et elle est isolée au point 3.
- Stop si le périmètre tend à s'étendre à `TopRightControls`, `SkipIntroButton` ou `NextEpisodeOverlay` : ils sont montés par `player_screen.dart`, que ce plan garde fermé.

## Design documentation

- Après acceptation et validation : préciser dans `PROJECT_DESIGN.md` §10 que le « control fade » est porté par `app/lib/widgets/global/player_chrome_fade.dart` — fondu d'opacité de 200 ms `easeOut`, symétrique, insensible au pointeur quand masqué — et qu'il est le seul mécanisme d'apparition/disparition des trois chromes du lecteur. Noter dans la même passe que le chrome ne glisse plus. Ne pas modifier `design.md`, qui est le brief incumbent superseded.
