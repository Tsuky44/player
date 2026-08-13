# Une seule marque, conforme aux tokens, et un chrome d'Accueil qui réutilise les owners du shell

Written against: `059dcc264c305f18369db4cd1a350bc8514149b6` (2026-07-18)

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web. Il n'y a pas trois bases de code : `MainShell` choisit une branche de rendu via `AppLayout.isWide(context)` — vrai si la largeur ≥ 900 px (`app/lib/utils/responsive.dart:21-22`). Le web tombe dans l'une ou l'autre branche selon la taille de fenêtre. Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine ; les tokens exécutés sont dans `app/lib/theme/app_colors.dart`.

## Evidence chain

- Surface : en-tête de l'app sur les deux branches — `_DesktopGlassHeader` (`app/lib/screens/shell/main_shell.dart:115-192`) pour ≥900 px, `_HomeOverlayBar` (`app/lib/screens/home/home_screen.dart:281-370`) pour l'onglet Accueil <900 px.
- Problème : deux défauts d'une même racine.
  1. `GlassBrand` peint la tuile de marque avec `LinearGradient(colors: [Color(0xFFE50914), Color(0xFFB20710)])` (`app/lib/widgets/global/glass_chrome.dart:190-195`) — le rouge Netflix, explicitement banni.
  2. `_HomeOverlayBar` ne consomme pas le chrome du shell : il redessine localement une tuile de marque bleue 32×32 rayon 6 (`app/lib/screens/home/home_screen.dart:310-318`) et un menu compte complet (`home_screen.dart:334-363`) en parallèle de `_AccountMenu` (`main_shell.dart:373-427`). Les deux menus divergent sur le libellé de la même action — « Déconnexion » (`home_screen.dart:361`) contre « Se déconnecter » (`main_shell.dart:398`) — et sur la présentation de l'avatar (`CircleAvatar` rayon 16 sur fond `surfaceElevated` @0.8 contre `GlassIconButton` size 34). Le menu du shell porte en plus un en-tête username et deux `PopupMenuDivider` que celui de l'Accueil n'a pas.
- Design evidence :
  - `PROJECT_DESIGN.md` §6 Color Palette & Roles : « Constraints: **no `#E50914`** ».
  - `PROJECT_DESIGN.md` §11 Don't : « Netflix red, purple gradients, neon glow ».
  - `PROJECT_DESIGN.md` §2 Existing UI Read, « Patterns to remove or avoid » : « rouge Netflix ».
  - `PROJECT_DESIGN.md` §11 Do : « Align shell + player + login on same tokens ».
  - `design.md:107` : « No Netflix-red branding; the mark is a light play tile on dark. »
- Owner : `app/lib/widgets/global/glass_chrome.dart` (`GlassBrand`) pour la marque ; `app/lib/screens/shell/main_shell.dart` (`_AccountMenu`) pour le menu compte.
- Scope and affected surfaces : `app/lib/widgets/global/glass_chrome.dart`, `app/lib/screens/shell/main_shell.dart`, `app/lib/screens/home/home_screen.dart`.
- Uncertainty : `_AccountMenu` est privé à `main_shell.dart` ; il faut le rendre public (ou l'extraire) pour que `home_screen.dart` le consomme. Aucune autre incertitude.

## Design decision

`GlassBrand` devient l'unique owner de la marque et rend une tuile claire sur fond sombre au lieu du dégradé rouge ; `_HomeOverlayBar` cesse de réimplémenter le chrome et consomme `GlassBrand` et le menu compte du shell.

Cela résout la racine plutôt que le symptôme : tant que l'Accueil mobile garde sa copie locale, toute correction de tokens sur le chrome desktop laisse mobile et web étroit derrière. Un seul owner par élément de chrome garantit que la marque et le menu compte sont identiques sur les quatre cibles, et supprime au passage la contradiction de libellé « Déconnexion » / « Se déconnecter » sur la même action.

## Reuse

- Token : `AppColors.textPrimary` (`#F5F5F7`) pour le remplissage clair, `AppColors.background` (`#0A0A0A`) pour l'icône dessus.
- Composant : `GlassBrand` (`app/lib/widgets/global/glass_chrome.dart:174-219`), `GlassIconButton` (`glass_chrome.dart:268-301`).
- Exemplar du couple « surface claire pleine / contenu sombre » : `app/lib/theme/app_theme.dart:84-86` — `elevatedButtonTheme` avec `backgroundColor: AppColors.textPrimary`, `foregroundColor: AppColors.background`. Le même couple est déjà appliqué au bouton primaire du login (`app/lib/screens/auth/login_screen.dart:209`).

Aucun nouveau primitive n'est requis : les deux owners existent déjà et sont déjà consommés par la branche desktop.

## Changes

1. `app/lib/widgets/global/glass_chrome.dart` — `GlassBrand`
   - Change : remplacer le `gradient: LinearGradient(...[Color(0xFFE50914), Color(0xFFB20710)])` du `Container` (lignes 189-195) par `color: AppColors.textPrimary`, et passer l'icône `Icons.play_arrow_rounded` de `Colors.white` à `AppColors.background`.
   - Preserve : dimensions 28×28, `BorderRadius.circular(8)`, taille d'icône 18, l'espacement de 8 et le wordmark `PLAYEUR` avec son `letterSpacing: 1.6` et son ombre portée, le `onTap` optionnel.
   - Verify : aucune occurrence de `E50914` ni `B20710` ne subsiste dans `app/lib`, et la tuile s'affiche claire avec un chevron sombre.

2. `app/lib/screens/shell/main_shell.dart` — `_AccountMenu`
   - Change : renommer `_AccountMenu` en `AccountMenu` (public) pour permettre sa consommation depuis `home_screen.dart`, ou l'extraire tel quel dans `app/lib/widgets/global/` si l'exécutant préfère éviter un import de `screens/shell` depuis `screens/home`. Mettre à jour les deux points d'usage existants (`main_shell.dart:103` et `main_shell.dart:171`).
   - Preserve : contenu et ordre du menu — en-tête username non cliquable, `PopupMenuDivider`, « Paramètres », « Player Studio », `PopupMenuDivider`, « Se déconnecter » — ainsi que l'`offset: Offset(0, 44)`, la couleur `AppColors.surfaceElevated.withValues(alpha: 0.96)` et les destinations de navigation.
   - Verify : le menu compte du shell se comporte à l'identique sur desktop après le renommage.

3. `app/lib/screens/home/home_screen.dart` — `_HomeOverlayBar`
   - Change : remplacer le `Container` de marque local (lignes 310-318) par `GlassBrand()`, et remplacer le `PopupMenuButton<String>` local (lignes 334-363) par le composant public de l'étape 2. Supprimer les imports devenus inutilisés (`SettingsScreen`, `PlayerStudioScreen`) si plus aucune autre référence ne subsiste dans le fichier.
   - Preserve : la structure de la barre — `AnimatedContainer` 200 ms, le passage à `AppColors.background` opaque + `boxShadow` au-delà de 80 px de scroll (`home_screen.dart:294-303`), le `SafeArea`, le padding `fromLTRB(16, 4, 12, 8)`, l'`InlineCatalogSearch` en `Expanded`, et l'indicateur de progression conditionnel (lignes 322-333). `_HomeOverlayBar` ne doit être monté que quand `embedded == false` (`home_screen.dart:264`).
   - Verify : sur une fenêtre <900 px, l'onglet Accueil affiche la même tuile de marque claire que le desktop et un menu compte dont la dernière entrée lit « Se déconnecter ».

## Scope

- Inherit : `_DesktopGlassHeader` (desktop macOS/Windows et web ≥900 px), `_HomeOverlayBar` (Android et web <900 px).
- Verify : la barre mobile des onglets Films/Séries/Demandes (`main_shell.dart:86-108`) consomme déjà `_AccountMenu` — confirmer qu'elle rend toujours l'avatar `GlassIconButton` après le renommage. Vérifier aussi le rendu de la marque claire par-dessus le `GlassHeaderStrip` (dégradé noir 35 %→12 %, `glass_chrome.dart:19-30`) et par-dessus le hero de l'Accueil en haut de scroll.
- Exclude : les onglets de navigation `GlassNavTab` en pilule pleine (`glass_chrome.dart:242-249`) — `PROJECT_DESIGN.md` §8 dit « accent underline/dot not filled pill blob », mais le brief propose deux corrections alternatives et n'en détermine aucune ; hors périmètre de ce plan. Exclure également l'icône applicative et les assets de `app/web/icons`, `app/macos`, `app/windows`, `app/android` : ce plan ne touche que la marque rendue dans l'UI.

## Validation

- Product : se connecter, arriver sur l'Accueil, ouvrir le menu compte, aller dans Paramètres, revenir. Le parcours doit être inchangé et aucune entrée de menu ne doit manquer.
- Interface : Accueil, Films, Séries, Demandes, aux largeurs 375, 600, 899, 901 et 1440 px. Vérifier l'Accueil en haut de scroll (barre translucide) et après 80 px de scroll (barre opaque). Vérifier le cas où `currentUser` est nul — `main_shell.dart:417` indexe `(username ?? '?')[0]`, l'initiale doit rester `?`.
- System : après le changement, `GlassBrand` doit être le seul endroit du dépôt qui dessine la tuile de marque, et le menu compte ne doit exister qu'en un exemplaire.
- Repository :
  - `grep -rn "E50914\|B20710" app/lib` → aucun résultat.
  - `grep -rn "Déconnexion" app/lib` → aucun résultat (seul « Se déconnecter » subsiste).
  - `grep -rn "PopupMenuItem(value: 'logout'" app/lib` → une seule occurrence.
  - `cd app && flutter analyze lib/widgets/global/glass_chrome.dart lib/screens/shell/main_shell.dart lib/screens/home/home_screen.dart` → `No issues found`.

## Stop conditions

- Stop si `_AccountMenu` s'avère dépendre d'un état privé de `_MainShellState` qui ne peut pas être passé en paramètre.
- Stop si l'extraction du menu compte crée une dépendance circulaire entre `screens/home` et `screens/shell` — dans ce cas, extraire le composant dans `app/lib/widgets/global/` plutôt que de le rendre public sur place.
- Stop si la tuile claire s'avère illisible par-dessus le hero à fort contraste : signaler plutôt que d'inventer un traitement (ombre, contour) non documenté.

## Design documentation

- Après acceptation et validation : consigner dans `PROJECT_DESIGN.md` §8 Component Styling que la marque est une tuile `AppColors.textPrimary` 28×28 rayon 8 avec chevron `AppColors.background`, rendue par l'unique owner `GlassBrand`, sur toutes les branches de largeur. Ne pas modifier `design.md`, qui est le brief incumbent superseded.
