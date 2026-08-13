# Design plans — Playeur

Plans d'implémentation issus de l'audit UI. Chaque plan est autonome : son exécutant n'a pas besoin de l'audit ni de la conversation d'origine.

Écrits contre `059dcc264c305f18369db4cd1a350bc8514149b6` (2026-07-18).

| Plan | Résultat visé | Fichiers touchés | Ordre |
| --- | --- | --- | --- |
| [01 — Marque et chrome Accueil](01-marque-et-chrome-accueil.md) | Supprimer le rouge Netflix de la marque et faire consommer au chrome de l'Accueil mobile les owners du shell (marque + menu compte) | `glass_chrome.dart`, `main_shell.dart`, `home_screen.dart` | 1er |
| [02 — Demandes sur les tokens](02-demandes-tokens.md) | Remplacer la palette Tailwind parallèle de l'onglet Demandes par les tokens `AppColors` | 6 fichiers de `screens/requests/` | indépendant |
| [03 — Cartes poster](03-cartes-poster.md) | Un seul rayon (12) et un seul liseré de survol (1 px blanc 16 %) sur les trois cartes poster | `media_card.dart`, `continue_watching_card.dart`, `request_media_card.dart` | indépendant |

Les trois plans ne se chevauchent pas et peuvent être exécutés dans n'importe quel ordre. Seule intersection à connaître : le plan 02 et le plan 03 touchent tous deux `screens/requests/widgets/request_media_card.dart` — le 02 change ses couleurs de pastille de statut, le 03 lui ajoute un état de survol. Si les deux sont exécutés, faire le 02 d'abord.

Audit d'origine et findings écartés : [audit-ui.md](audit-ui.md).
