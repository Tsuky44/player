# L'onglet Demandes rend les tokens Quiet Premium au lieu de sa palette parallèle

Written against: `059dcc264c305f18369db4cd1a350bc8514149b6` (2026-07-18)

## Contexte pour l'exécutant

Le dépôt est une app Flutter unique (`app/lib`) déployée sur macOS, Windows, Android et web ; il n'y a pas de code séparé par plateforme, donc chaque correction ci-dessous vaut pour les trois cibles. Le brief de design gouvernant est `PROJECT_DESIGN.md` à la racine, et les tokens réellement exécutés sont dans `app/lib/theme/app_colors.dart`. L'onglet « Demandes » est le quatrième onglet du shell (`app/lib/screens/shell/main_shell.dart:62`) et a manifestement été porté depuis un autre produit (les commentaires du code citent « MediaHub », p. ex. `request_media_card.dart:115`, `request_detail_screen.dart:348`) en gardant sa palette d'origine — des couleurs Tailwind (slate/blue/green/amber/purple).

## Evidence chain

- Surface : onglet Demandes — `RequestsScreen` (`app/lib/screens/requests/requests_screen.dart`) et tout ce qu'il ouvre : `request_detail_screen.dart`, `widgets/request_media_card.dart`, `widgets/request_status_badge.dart`, `widgets/request_season_list.dart`, `widgets/season_selector_dialog.dart`, `widgets/request_info_table.dart`.
- Problème :
  1. **Fond hors token.** `requests_screen.dart:113` utilise correctement `AppColors.background` (`#0A0A0A`), mais l'écran de détail qu'il ouvre pose `Scaffold(backgroundColor: Color(0xFF0F172A))` (`request_detail_screen.dart:90`, repris lignes 216, 223-225, 237) — un navy Tailwind slate-900. Naviguer de la grille vers la fiche fait virer le fond du charcoal au bleu.
  2. **Violet interdit.** Le statut « partiellement disponible » est rendu en `#C084FC`/`#A855F7` (`request_detail_screen.dart:362-363`, `request_media_card.dart:130`).
  3. **Le même statut a deux couleurs sur le même écran.** Sur la fiche détail, « Disponible » s'affiche à la fois via `RequestAvailabilityBadge` en `AppColors.success` (`request_detail_screen.dart:302` → `request_status_badge.dart:16-19`) et via le bouton d'état en `#4ADE80`/`#22C55E` (`request_detail_screen.dart:382-383`). Idem pour « partiel » : `AppColors.warning` dans le badge (`request_status_badge.dart:22`) contre violet dans le bouton.
  4. **Accent en aplat.** `_primaryButton` remplit son état principal de `#3B82F6` (`request_detail_screen.dart:500`) et borde son état secondaire de rouge `#EF4444` @55 % (`request_detail_screen.dart:503`).
- Design evidence :
  - `PROJECT_DESIGN.md` §6 : rôles de couleur (`Background #0A0A0A`, `Surface elevated #1C1C1C`, `Accent #0A84FF`, `Success #30D158`, `Warning #FF9F0A`, `Error #FF453A`) et « Constraints: accent ≤ ~5% surface ; **pas de purple/neon** ».
  - `PROJECT_DESIGN.md` §11 Don't : « Netflix red, **purple gradients**, neon glow ».
  - `PROJECT_DESIGN.md` §11 Do : « Use accent only for focus, selection, progress, links » et « Align shell + player + login on same tokens ».
  - `PROJECT_DESIGN.md` §8 Buttons : « Primary: fill blanc 92% / text near-black ; radius 12 » — « Secondary: glass or hairline border white 12% ».
- Owner : `app/lib/theme/app_colors.dart` pour les valeurs ; `app/lib/screens/requests/widgets/request_status_badge.dart` pour la sémantique statut → token, déjà correcte dans `RequestAvailabilityBadge`.
- Scope and affected surfaces : les six fichiers de `app/lib/screens/requests/` listés ci-dessus.
- Uncertainty : aucune sur les couleurs. `PROJECT_DESIGN.md` §6 ne définit pas de rôle « violet » ; la correction du statut *partiel* est déterminée par le traitement déjà retenu pour ce même statut dans `request_status_badge.dart:20-25` (`AppColors.warning`), pas inventée.

## Design decision

Remplacer tous les littéraux de couleur de `app/lib/screens/requests/` par les tokens `AppColors`, en prenant `RequestAvailabilityBadge` comme référence de la correspondance statut → token, et en cessant d'utiliser l'accent comme aplat de bouton.

C'est la racine et non le symptôme : la fiche détail n'est pas « un peu trop bleue », c'est toute la branche Demandes qui exécute une seconde palette. Corriger un écran isolé laisserait la transition grille → fiche → dialogue changer de teinte. Une seule table de correspondance appliquée d'un coup supprime aussi la contradiction où « Disponible » a deux verts sur le même écran.

## Reuse

- Tokens : `AppColors.background`, `AppColors.surfaceElevated`, `AppColors.primary`, `AppColors.accentMuted`, `AppColors.success`, `AppColors.warning`, `AppColors.error`, `AppColors.textPrimary`.
- Exemplar de la sémantique statut → token : `app/lib/screens/requests/widgets/request_status_badge.dart:13-35` (`RequestAvailabilityBadge`) — `available → success`, `partial → warning`, `pending`/`processing → accentMuted` avec fond `primary`.
- Exemplar du dérivé fond/bordure à partir d'un token sémantique : `request_status_badge.dart:52-59` (`_HeroBadge`) — fond `token.withValues(alpha: 0.14)`, bordure `token.withValues(alpha: 0.28)`.
- Exemplar du bouton primaire : `app/lib/theme/app_theme.dart:83-97` (`elevatedButtonTheme` : fond `AppColors.textPrimary`, texte `AppColors.background`, rayon 12), déjà appliqué au login (`app/lib/screens/auth/login_screen.dart:209`).
- Exemplar de l'étoile de note : `app/lib/widgets/global/media_detail_widgets.dart:277` (`RatingBadge`, `Color(0xFFF5C518)`).

Aucun nouveau token n'est requis.

## Changes

1. `app/lib/screens/requests/request_detail_screen.dart` — fonds
   - Change : remplacer les six occurrences de `Color(0xFF0F172A)` (lignes 90, 216, 223, 224, 225, 237) par `AppColors.background`.
   - Preserve : les alphas des dégradés (0.92 / 0.55 / 0.2) et la structure du backdrop hero.
   - Verify : passer de la grille Demandes à une fiche ne change plus la teinte du fond.

2. `app/lib/screens/requests/request_detail_screen.dart` — boutons d'état
   - Change : `#C084FC`/`#A855F7` (lignes 362-363) → `AppColors.warning` ; `#4ADE80`/`#22C55E` (lignes 382-383) → `AppColors.success` ; `#FACC15`/`#EAB308` (lignes 403-404) → premier plan `AppColors.accentMuted` sur fond `AppColors.primary`.
   - Table statut → token de référence, reprise de `RequestAvailabilityBadge` (`request_status_badge.dart:13-35`) : `available → success` · `partial → warning` · `pending`/`processing → accentMuted sur fond primary`. Ne pas fusionner `partial` et `pending` sur le même token : ils cohabitent dans la même grille et ne seraient plus distinguables.
   - Preserve : les libellés (« Partiellement disponible », « Disponible », « En cours de traitement... »), les icônes et la logique conditionnelle de `_requestActions`.
   - Verify : sur une fiche « Disponible », le badge hero et le bouton d'état affichent exactement le même vert.

3. `app/lib/screens/requests/request_detail_screen.dart` — `_primaryButton` (lignes 491-505)
   - Change : état `filled` → fond `AppColors.textPrimary`, texte/icône `AppColors.background`, rayon 12 ; état non rempli → fond `Colors.white.withValues(alpha: 0.06)` conservé et bordure `Colors.white.withValues(alpha: 0.12)` au lieu de `Color(0xFFEF4444).withValues(alpha: 0.55)`.
   - Preserve : les états `enabled`/`loading`, l'atténuation à 0.35 quand désactivé, la structure `Material` + `InkWell`.
   - Verify : le bouton « Demander » a le même aspect que le bouton primaire du login ; plus aucune bordure rouge sur un bouton qui n'exprime pas une erreur.

4. `app/lib/screens/requests/widgets/request_status_badge.dart` — `_SeasonBadge` (lignes 82-103)
   - Change : supprimer les six fonds/bordures littéraux (`#123526`/`#1B4D34`, `#3A2A10`/`#5C4014`, `#0F2744`/`#163A63`) et les dériver du token de premier plan comme le fait `_HeroBadge` — fond `foreground.withValues(alpha: 0.14)`, bordure `foreground.withValues(alpha: 0.28)`.
   - Preserve : les libellés, les icônes (`check_rounded`, `schedule_rounded`), le padding compact (h8/v3) et le rayon 999.
   - Verify : les pastilles de saison et le badge hero partagent la même famille de teintes pour un statut donné.

5. `app/lib/screens/requests/widgets/request_media_card.dart` — `_StatusDot` (lignes 125-137)
   - Change : `#22C55E` → `AppColors.success` ; `#A855F7` → `AppColors.warning` ; `#EAB308` → `AppColors.accentMuted`.
   - Preserve : les tooltips (« Disponible », « Partiellement disponible », « En attente ») et le positionnement du dot.
   - Verify : la pastille d'une carte de la grille correspond au badge de la fiche qu'elle ouvre.

6. `app/lib/screens/requests/widgets/request_season_list.dart`
   - Change : `#0F172A` (lignes 257, 483) → `AppColors.background` ; `#1E293B` (ligne 414) → `AppColors.surfaceElevated` ; `#3B82F6` (ligne 280, spinner) → `AppColors.primary` ; `#FBBF24` (ligne 402, étoile de note) → `Color(0xFFF5C518)`, la valeur déjà utilisée par `RatingBadge`.
   - Preserve : la mise en page compacte/large de la liste d'épisodes et les placeholders « N/A ».
   - Verify : les étoiles de note des épisodes de Demandes ont la même couleur que celles des fiches de la bibliothèque.

7. `app/lib/screens/requests/widgets/season_selector_dialog.dart`
   - Change : `#111827` (ligne 78, fond du `Dialog`) → `AppColors.surfaceElevated`, cohérent avec `dialogTheme` (`app_theme.dart:135-138`) ; `#60A5FA` (ligne 145) → `AppColors.primary` ; `#1E3A5F` (ligne 187, fond de ligne sélectionnée) → `AppColors.primary.withValues(alpha: 0.16)` ; `#3B82F6` (lignes 200, 213, 219 — bordure et case cochée) → `AppColors.primary` ; `#3B82F6` du `FilledButton` (lignes 305, 307) → fond `AppColors.textPrimary`, texte `AppColors.background`, état désactivé à alpha 0.3 conservé.
   - Preserve : la sélection multiple, l'action « tout sélectionner », les contraintes `maxWidth: 480, maxHeight: 560` et le rayon 16 du dialogue.
   - Verify : la sélection d'une saison est lisible et l'accent ne sert plus que d'indicateur de sélection.

## Scope

- Inherit : l'onglet Demandes sur macOS, Windows, Android et web — c'est le même arbre de widgets sur les quatre cibles.
- Verify : `requests_screen.dart` utilise déjà `AppColors` (lignes 113, 116, 142, 309, 322) ; confirmer qu'il n'apparaît aucune régression de contraste sur les filtres et le FAB une fois que le reste du flux passe au charcoal. Vérifier aussi les états vides et d'erreur du flux Demandes, qui héritent maintenant d'un fond plus sombre.
- Exclude : `app/lib/screens/requests/widgets/request_info_table.dart:139` (`#F5C518`) et `:146` (`#01D277`) — ce sont les couleurs de marque d'IMDb et de TMDB sur des badges explicitement libellés « IMDb » et « TMDB ». Le dépôt les traite déjà ainsi côté bibliothèque (`media_detail_widgets.dart:277`) ; ce sont des marques tierces, pas de la dérive de palette. Exclure également toute modification de mise en page, de copie ou de comportement de requête : ce plan ne touche que des valeurs de couleur (plus le remplissage et le rayon du bouton primaire au point 3).

## Validation

- Product : ouvrir Demandes, filtrer, ouvrir une fiche film disponible, une fiche série partiellement disponible, lancer le sélecteur de saisons et soumettre une demande. Le flux doit être fonctionnellement inchangé.
- Interface : grille Demandes, fiche détail (statuts `available`, `partial`, `pending`, `processing`, `unknown`), liste des saisons, dialogue de sélection, états vide / chargement / erreur — aux largeurs 375, 600, 899, 901 et 1440 px. Vérifier un titre très long et une série à 20+ saisons.
- System : après le changement, la sémantique statut → couleur ne doit exister qu'en un endroit conceptuel (les tokens `AppColors`), et aucun nouveau littéral hexadécimal ne doit être introduit.
- Repository :
  - `grep -rnE "Color\(0xFF(0F172A|1E293B|111827|3B82F6|60A5FA|1E3A5F|22C55E|4ADE80|A855F7|C084FC|EAB308|FACC15|FBBF24|EF4444|123526|1B4D34|3A2A10|5C4014|0F2744|163A63)\)" app/lib/screens/requests` → aucun résultat.
  - `grep -rn "Color(0x" app/lib/screens/requests` → uniquement `request_info_table.dart:139` et `:146` (IMDb / TMDB).
  - `cd app && flutter analyze lib/screens/requests` → `No issues found`.

## Stop conditions

- Stop si un des littéraux visés porte en réalité une distinction sémantique absente de `AppColors` (autre chose que disponible / partiel / en attente / erreur) : signaler plutôt que d'inventer un rôle de couleur.
- Stop si le passage du fond navy au charcoal rend un texte illisible faute de contraste suffisant : signaler la paire concernée plutôt que d'ajuster un token global.
- Stop si le périmètre doit s'étendre hors de `app/lib/screens/requests/`.

## Design documentation

- Après acceptation et validation : ajouter dans `PROJECT_DESIGN.md` §6 la table statut → token (`available → success`, `partial → warning`, `pending`/`processing → accentMuted sur fond primary`, erreur → `error`), afin que la prochaine surface portée depuis un autre produit ait une référence explicite. Ne pas modifier `design.md`.
