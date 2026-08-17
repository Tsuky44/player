# L'app a un owner de mouvement, et il respecte « réduire les animations »

Written against: `c549dde` (2026-08-15)

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web ; il n'y a pas de code séparé par plateforme, donc ce plan vaut pour les quatre cibles. Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine. Les tokens réellement exécutés vivent dans `app/lib/theme/` : `app_colors.dart` (couleur) et `app_theme.dart` (forme, texte, composants Material).

Ce plan est le **prérequis** des plans [05](05-fondu-chrome-lecteur.md) et [06](06-retroaction-appui.md), qui sont ses deux premiers consommateurs. Il doit être exécuté avant eux. Il ne migre **pas** les animations existantes de l'app : il crée l'owner et le câble sur un seul consommateur trivial pour prouver qu'il fonctionne.

## Evidence chain

- Surface : toutes les animations de l'app — 35 widgets animés implicites répartis sur les quatre onglets, les fiches détail et les trois chromes du lecteur.
- Problème : `app/lib/theme/` définit couleur, forme et typographie, mais **aucun token de mouvement**. Chaque site d'appel décide seul :
  - **18 durées distinctes codées en dur**, de 80 ms à 1500 ms. Le brief en autorise une plage de 180 à 280 ms ; au moins six valeurs en sortent (`80`, `120`, `140`, `150`, `160`, `300`, `320`, `350`, `400`, `420`, `500`, `800`, `900`, `1500`).
  - **5 courbes distinctes** (`easeOut` ×24, `easeOutCubic` ×12, `easeIn` ×2, `easeInOut` ×1, `easeInOutCubic` ×1) là où le brief en nomme une seule.
  - **0 lecture de `MediaQuery.disableAnimations`** sur les 138 fichiers Dart. Le réglage système « Réduire les animations » (macOS/iOS) et « Supprimer les animations » (Android) n'a aucun effet dans l'app.
  - **0 `SpringDescription` / `SpringSimulation`** : aucune animation ne peut repartir de la vélocité courante.
- Design evidence :
  - `PROJECT_DESIGN.md` §10 Depth, Motion, And Interaction (ligne 128) : « Motion: **180–280ms ease-out** ; hero crossfade ; control fade ; **respect `disableAnimations` / reduced motion** ». Les trois clauses sont violées.
  - `PROJECT_DESIGN.md` §2 (ligne 22), Accessibility : « dark contrast, 44px targets mobile, focus desktop, **reduced motion** ».
  - `PROJECT_DESIGN.md` §4 (ligne 38), non-transferable : « scale-on-focus **1.1 agressif** » — la valeur d'échelle interactive doit rester discrète.
  - Skill apple-design §4 : deux paramètres lisibles par un designer (amortissement, réponse) plutôt qu'un triplet physique ou une liste de durées ; §14 : le mouvement réduit n'est pas l'absence de retour, c'est un retour non vestibulaire — « replace slides/springs/parallax with short opacity cross-fades », « **keep opacity/color changes that aid comprehension** ».
- Owner : n'existe pas. Ce plan le crée : `app/lib/theme/app_motion.dart`, voisin de `app_colors.dart` et `app_theme.dart`.
- Scope and affected surfaces : `app/lib/theme/app_motion.dart` (nouveau), `app/lib/widgets/global/glass_chrome.dart` (premier consommateur).
- Uncertainty :
  - Le brief donne une plage (180–280 ms), pas une valeur. Le dépôt a déjà tranché en pratique : `200 ms` est la valeur du fondu de chrome qui ship aujourd'hui (`emby_controls_layer.dart:185`) et `180 ms` celle des onglets de nav (`glass_chrome.dart:232`). Les deux sont dans la plage ; ce plan les retient comme `standard` et `micro`.
  - « Response » au sens Apple **n'est pas une durée** : c'est un paramètre de ressort dont le temps de stabilisation émerge. La plage 180–280 ms du brief gouverne les animations à durée (fondus, transitions implicites) ; elle ne s'applique pas littéralement au paramètre de ressort. Ce plan expose les deux et documente la distinction dans le fichier.

## Design decision

Créer `AppMotion` : un owner unique qui expose **trois durées**, **une courbe**, **une échelle d'appui** et **deux helpers de mouvement réduit**, et rien d'autre.

L'alternative — corriger les 18 durées à la main — traite le symptôme. Tant qu'il n'y a pas d'owner, la prochaine animation écrite dans l'app repartira d'une valeur inventée, et le respect de `disableAnimations` restera à recoder à chaque site d'appel. Un owner rend la clause d'accessibilité du brief vraie **par construction** : un widget qui lit `AppMotion.move(context)` obtient `Duration.zero` sous mouvement réduit sans que son auteur ait à y penser.

La distinction `fade` / `move` porte la nuance de §14 et n'est pas cosmétique : un fondu d'opacité n'est pas vestibulaire, il doit **survivre** au mouvement réduit ; une translation ou une mise à l'échelle doit disparaître. Une seule fonction « animations désactivées » supprimerait les deux et rendrait l'interface plus dure à comprendre, pas plus confortable.

## Reuse

- Valeurs : `200 ms` et `Curves.easeOut` sont déjà la combinaison qui ship dans `emby_controls_layer.dart:185-186` ; `180 ms` / `easeOut` celle de `glass_chrome.dart:232-233`. `AppMotion` ne propose aucune valeur nouvelle, il nomme celles qui existent déjà et sont dans la plage du brief.
- Primitive de plateforme : `MediaQuery.disableAnimationsOf` (Flutter ≥ 3.10 ; le SDK du projet est `>=3.0.0 <4.0.0`, `pubspec.yaml:6`). **Aucune dépendance à ajouter.**
- Convention de fichier : `abstract final class` avec des membres `static const`, exactement comme `AppColors` (`app/lib/theme/app_colors.dart:4`) et `AppTheme` (`app/lib/theme/app_theme.dart:5`).

**Ne pas** ajouter de package d'animation : `flutter_animate` est déjà au `pubspec.yaml:31` et sert dans cinq fichiers du lecteur ; il ne sait pas repartir d'une valeur courante et le plan 05 l'écarte du chrome. Ne pas non plus faire d'`AppMotion` un `InheritedWidget` ou un `ThemeExtension` : rien dans le produit ne demande de faire varier le mouvement par sous-arbre.

## Changes

1. `app/lib/theme/app_motion.dart` — **nouveau fichier**
   - Change : créer `abstract final class AppMotion` exposant exactement :
     - `static const Duration micro = Duration(milliseconds: 180)` — micro-états (survol, sélection d'onglet).
     - `static const Duration standard = Duration(milliseconds: 200)` — valeur par défaut : fondus de chrome, apparitions/disparitions.
     - `static const Duration emphasis = Duration(milliseconds: 260)` — surfaces larges (feuilles, panneaux).
     - `static const Curve curve = Curves.easeOut` — la seule courbe du produit, conforme à `PROJECT_DESIGN.md` §10.
     - `static const double pressScale = 0.97` — échelle d'appui, consommée par le plan 06. Volontairement discrète : `PROJECT_DESIGN.md` §4 classe le « scale-on-focus 1.1 » du brief incumbent comme non transférable.
     - `static bool reduced(BuildContext c) => MediaQuery.disableAnimationsOf(c);`
     - `static Duration fade(BuildContext c, [Duration d = standard]) => d;` — l'opacité et la couleur **survivent** au mouvement réduit (§14).
     - `static Duration move(BuildContext c, [Duration d = standard]) => reduced(c) ? Duration.zero : d;` — translation, échelle et taille sont annulées sous mouvement réduit.
   - Documenter en tête du fichier, en commentaire : (a) que la plage 180–280 ms vient de `PROJECT_DESIGN.md` §10 et qu'aucune durée hors plage ne doit être ajoutée ici ; (b) pourquoi il n'y a **aucun ressort** dans ce fichier — un ressort n'a d'intérêt que là où un geste porte une vélocité à transmettre (relâchement de drag, flick), ce que l'app ne fait nulle part aujourd'hui ; les animations implicites de Flutter repartent déjà de la valeur affichée, ce qui suffit à les rendre interruptibles. Le jour où le scrubber accroche les chapitres au flick, la formule à utiliser est `stiffness = mass * (2π / réponse)²` avec `SpringDescription.withDampingRatio(ratio: amortissement)` — noter cette formule en commentaire pour qu'elle soit calculée et non devinée.
   - Preserve : sans objet, fichier neuf. Ne rien y mettre d'autre — pas de couleur, pas d'espacement, pas de widget.
   - Verify : `AppMotion.fade(context)` renvoie 200 ms avec et sans mouvement réduit ; `AppMotion.move(context)` renvoie 200 ms normalement et `Duration.zero` sous mouvement réduit.

2. `app/lib/widgets/global/glass_chrome.dart`
   - Change : dans `GlassNavTab`, remplacer `duration: const Duration(milliseconds: 180)` (ligne 232) par `duration: AppMotion.move(context, AppMotion.micro)` et `curve: Curves.easeOut` (ligne 233) par `curve: AppMotion.curve`. Ajouter l'import de `../../theme/app_motion.dart`.
   - Rationale du choix de `move` plutôt que `fade` ici : l'`AnimatedContainer` de la ligne 231 anime un `padding` et une `decoration`, donc de la géométrie — c'est le cas que §14 demande d'annuler.
   - Preserve : la pilule blanche 14 % sur l'onglet sélectionné, les poids de police w700/w500, l'ombre portée sur les onglets non sélectionnés, le rayon 16, l'`InkWell` et son `onTap`. Ne rien changer d'autre dans ce fichier — `GlassHeaderStrip`, `GlassSurface`, `GlassSearchInput`, `GlassBrand` et `GlassIconButton` sont hors périmètre.
   - Verify : cliquer entre Accueil / Films / Séries / Demandes sur une fenêtre ≥ 900 px ; la pilule se déplace comme avant. Activer « Réduire les animations » au niveau système : la pilule saute d'un onglet à l'autre sans transition, et rien d'autre ne change.

## Scope

- Inherit : rien pour l'instant. C'est délibéré — l'owner est créé ici, les plans 05 et 06 sont ses deux premiers vrais consommateurs.
- Verify : `MediaQuery.disableAnimationsOf` demande un `BuildContext` sous un `MaterialApp`. `GlassNavTab.build` en a un (`glass_chrome.dart:223`). Tout futur consommateur devra en avoir un aussi — c'est pourquoi `fade`/`move` prennent le contexte en premier paramètre plutôt que d'être des constantes.
- Exclude : la migration des 17 autres durées de l'app, les cinq usages de `flutter_animate`, le carrousel de l'Accueil (`hero_carousel.dart`, 7 s / 900 ms — il a son propre finding), `pageTransitionsTheme`, et toute modification d'`app_theme.dart`. Ce plan n'ajoute pas `AppMotion` au `ThemeData`.

## Validation

- Product : naviguer entre les quatre onglets sur desktop ; aucun changement fonctionnel attendu.
- Interface : en-tête desktop aux largeurs 901 et 1440 px, onglet sélectionné et non sélectionné, avec et sans « Réduire les animations ».
- System : après ce plan, `app/lib/theme/` contient trois owners (couleur, thème, mouvement) et un seul widget lit le troisième. Aucune valeur de durée hors de 180–280 ms ne doit exister dans `app_motion.dart`.
- Repository :
  - `grep -n "milliseconds" app/lib/theme/app_motion.dart` → exactement trois résultats : 180, 200, 260.
  - `grep -n "Spring" app/lib/theme/app_motion.dart` → aucun résultat hors commentaire.
  - `grep -n "Duration(milliseconds: 180)" app/lib/widgets/global/glass_chrome.dart` → aucun résultat.
  - `grep -rn "disableAnimationsOf" app/lib/` → au moins un résultat, dans `app_motion.dart`.
  - `cd app && flutter analyze lib/theme/app_motion.dart lib/widgets/global/glass_chrome.dart` → `No issues found`.

## Stop conditions

- Stop si `MediaQuery.disableAnimationsOf` n'est pas disponible sur la version de Flutter du poste : signaler la version plutôt que de retomber sur `MediaQuery.of(context).disableAnimations`, qui abonne le widget à **toutes** les MediaQuery et provoquerait des reconstructions parasites à chaque redimensionnement de fenêtre.
- Stop si l'exécution tend à ajouter à `AppMotion` autre chose que du mouvement (couleurs, espacements, helpers de widget) : le fichier doit rester lisible d'un coup d'œil, c'est sa seule raison d'être.
- Stop si le périmètre tend à s'étendre à la migration des durées existantes : ce plan crée l'owner et le prouve sur un consommateur. La migration se fait plan par plan, avec le contexte de chaque surface.

## Design documentation

- Après acceptation et validation : préciser dans `PROJECT_DESIGN.md` §10 que la plage 180–280 ms est portée par `app/lib/theme/app_motion.dart` (`micro` 180 / `standard` 200 / `emphasis` 260, courbe `easeOut`), que la clause « respect `disableAnimations` » est satisfaite via `AppMotion.fade` / `AppMotion.move`, et que l'opacité est conservée sous mouvement réduit alors que la géométrie est annulée. Ne pas modifier `design.md`, qui est le brief incumbent superseded.
