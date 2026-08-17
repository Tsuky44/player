# Design plans — Onyx

Plans d'implémentation issus des audits UI. Chaque plan est autonome : son exécutant n'a besoin ni de l'audit, ni de la conversation d'origine.

## Audits

| Audit | Périmètre | Date | État |
| --- | --- | --- | --- |
| [audit-ui.md](audit-ui.md) | Tokens statiques : couleur, rayon, palette parallèle | 2026-07-18 | Les 3 findings sont corrigés ; plans 01–03 exécutés |
| [audit-fluidite.md](audit-fluidite.md) | Mouvement, réponse à l'entrée, matière, typographie — grille apple-design | 2026-08-15 | 10 findings ; les 3 prioritaires sont couverts par les plans 04–06 |

## Vague 1 — tokens statiques

Écrits contre `059dcc264c305f18369db4cd1a350bc8514149b6` (2026-07-18). **Exécutés.**

| Plan | Résultat visé | Fichiers touchés | Ordre |
| --- | --- | --- | --- |
| [01 — Marque et chrome Accueil](01-marque-et-chrome-accueil.md) | Supprimer le rouge Netflix de la marque et faire consommer au chrome de l'Accueil mobile les owners du shell (marque + menu compte) | `glass_chrome.dart`, `main_shell.dart`, `home_screen.dart` | 1er |
| [02 — Demandes sur les tokens](02-demandes-tokens.md) | Remplacer la palette Tailwind parallèle de l'onglet Demandes par les tokens `AppColors` | 6 fichiers de `screens/requests/` | indépendant |
| [03 — Cartes poster](03-cartes-poster.md) | Un seul rayon (12) et un seul liseré de survol (1 px blanc 16 %) sur les trois cartes poster | `media_card.dart`, `continue_watching_card.dart`, `request_media_card.dart` | indépendant |

Les trois plans ne se chevauchent pas et peuvent être exécutés dans n'importe quel ordre. Seule intersection à connaître : le plan 02 et le plan 03 touchent tous deux `screens/requests/widgets/request_media_card.dart` — le 02 change ses couleurs de pastille de statut, le 03 lui ajoute un état de survol. Si les deux sont exécutés, faire le 02 d'abord.

## Vague 2 — mouvement et réponse à l'entrée

Écrits contre `c549dde` (2026-08-15). Couvrent les findings 1, 2 et 4 de [audit-fluidite.md](audit-fluidite.md).

| Plan | Résultat visé | Fichiers touchés | Ordre |
| --- | --- | --- | --- |
| [04 — Owner de mouvement](04-owner-de-mouvement.md) | Créer `AppMotion` (3 durées, 1 courbe, 1 échelle d'appui, 2 helpers de mouvement réduit) et rendre vraie la clause « respect `disableAnimations` » du brief | `theme/app_motion.dart` (nouveau), `glass_chrome.dart` | **1er — prérequis des deux suivants** |
| [05 — Fondu de chrome lecteur](05-fondu-chrome-lecteur.md) | Un seul fondu, 200 ms, symétrique, sur les trois chromes du lecteur — au lieu de 340 ms à l'entrée / 0 ms à la sortie / rien du tout | `player_chrome_fade.dart` (nouveau), les 3 layers du lecteur | après 04 |
| [06 — Rétroaction à l'appui](06-retroaction-appui.md) | Créer `Pressable` (appui, survol, focus) et le faire consommer par les deux cartes de contenu, pour que le tactile ait enfin un retour | `pressable.dart` (nouveau), `poster_card.dart`, `continue_watching_card.dart` | après 04 |

Le 04 est un prérequis strict : les 05 et 06 lisent ses tokens. Les 05 et 06 sont ensuite indépendants l'un de l'autre et ne partagent aucun fichier.

Intersection avec la vague 1 : le plan 06 touche `poster_card.dart` et `continue_watching_card.dart`, que le plan 03 a déjà alignés sur le rayon 12 et le liseré de survol 16 %. Le plan 06 **préserve** ces deux traitements et ne change que la source de l'état de survol — vérifier qu'ils sont toujours en place après exécution.

## Findings sans plan

Les findings 3 et 5 à 10 de [audit-fluidite.md](audit-fluidite.md) restent ouverts, sans plan écrit. Le plus proche d'être prêt est le **finding 3** (scrubbers qui affichent la position du décodeur au lieu de celle du doigt) : l'implémentation de référence existe déjà dans `emby_progress_bar.dart`, comme pour le 05.
