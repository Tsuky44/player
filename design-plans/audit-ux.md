# Audit UX — Onyx (app Flutter : desktop, mobile, web, TV)

Écrit le 2026-09-30, contre `63dd5ee9` plus l'arbre de travail non commité. Analyse **par lecture du code**, sans capture d'écran : les chiffres de largeur sont calculés, pas mesurés à l'écran.

Complète [audit-ui.md](audit-ui.md) (tokens statiques, 2026-07-18) et [audit-fluidite.md](audit-fluidite.md) (mouvement et matière, 2026-08-15). Celui-ci porte sur ce que les deux autres n'ont pas regardé : **les parcours, l'architecture de l'information, les droits, la découverte et le texte d'interface**. La dernière section fait le point sur les findings ouverts des audits précédents.

---

## A. Parcours et droits

### A1 — Les actions d'administration sont montrées à tout le monde, puis refusées par le serveur

> **Corrigé le 2026-09-30.** Les quatre points d'entrée lisent `permissions.manageLibrary` : `movie_detail_screen.dart`, `ShowMetadataMenu` (`screens/library/widgets/show_metadata_menu.dart`), l'accueil vide de `home_screen.dart`, et `ExtractSubtitlesButton` (`screens/player/widgets/extract_subtitles_button.dart`), qui remplace les deux copies du bouton d'extraction du lecteur. Épinglé par `test/library_admin_actions_test.dart`, dont un guard test qui refuse tout nouvel appel d'une route `manage_library` sans lecture du droit.

**Confiance : élevée. Impact : le plus élevé de l'audit.**

Le serveur protège ces routes par `manage_library` (`server/main.go:285-301` : `scan`, `redetect-all`, `metadata/redetect`, `metadata/rematch`, `subtitles/extract`). Côté app, rien ne lit `permissions.manageLibrary` avant de les proposer :

- Fiche film : bouton « Corriger la fiche » (`screens/library/movie_detail_screen.dart:363-368`), qui ouvre toute la feuille `MetadataFixSheet` — recherche TMDB, choix — avant que le serveur ne réponde 403 à la fin.
- Fiche série : menu « Métadonnées série » (relancer la détection, choisir sur TMDB) (`screens/library/show_detail_screen.dart:660-692`).
- Accueil vide : boutons « Synchroniser » et « Extraire les sous-titres » (`screens/home/home_screen.dart:235-238`).
- Lecteur : bouton « Extraire les sous-titres » sous la liste des pistes, recopié dans `player_subtitles_picker.dart` et `settings_menu.dart`.

Un membre de la famille voit un crayon sur chaque fiche, fait l'effort de corriger, et échoue. `permissions.manageLibrary` n'est lu aujourd'hui que dans les réglages (`screens/settings/pages/library_page.dart:166`).

**Correctif** : masquer ces entrées quand `!auth.permissions.manageLibrary`, comme `ShareMediaButton` le fait déjà pour `shareMedia` (`widgets/global/share_media_button.dart:40`). Pour l'accueil vide, remplacer le texte par « Demandez à l'administrateur d'ajouter des médias » chez un non-admin.

### A2 — Le texte de l'accueil vide renvoie vers un menu qui n'a pas l'action

> **Corrigé le 2026-09-30** avec A1.

**Confiance : élevée.**

`home_screen.dart:234` : « synchronisez depuis le menu profil ». Le menu profil (`widgets/global/account_menu.dart:39-105`) ne contient aucune entrée de synchronisation. La consigne est fausse — heureusement le bouton est juste en dessous. Réécrire : « Ajoutez des fichiers dans vos dossiers Films et Séries, puis lancez une synchronisation. »

### A3 — Une rangée d'actions de la fiche film déborde sur téléphone

> **Corrigé le 2026-09-30.** Débordement confirmé par un test avant correctif : 206 px à 360 px de large, y compris sur un film jamais commencé. `DetailActions` (`widgets/global/detail_actions.dart`) porte désormais la rangée des deux fiches : sur téléphone, lecture pleine largeur puis icônes, le tout sous l'image (`DetailBackdropHeader`) ; au-delà, un `Wrap`. Épinglé par `test/detail_actions_test.dart` à 360 et 700 px.

**Confiance : moyenne-élevée (calculée, pas vue).**

`DetailBackdropHeader` pose `actions` tel quel dans une `Column` (`widgets/global/media_detail_widgets.dart:198-201`). La fiche film lui passe un `Row` non contraint (`movie_detail_screen.dart:343-377`) : bouton « REPRENDRE » (~160 px) + `WatchedActionButton` **sans `compact: true`**, donc un `OutlinedButton` « Marquer non vu » (~170 px) + trois `IconButton` de 48 px + « 37 % visionné » (~100 px). Environ **590 px** pour **328 px** disponibles sur un téléphone de 360 px (gouttière 16 px, `utils/responsive.dart:25-29`).

`WatchedActionButton` a déjà un mode `compact` (`watched_action_button.dart:23`) que personne n'active ici.

**Correctif** : sur `AppLayout.isCompact`, bouton Lecture en pleine largeur sur sa ligne, puis une rangée d'icônes (vu, télécharger, partager, corriger) ; le pourcentage passe sous le titre ou dans la barre de progression. Sinon `Wrap(spacing: 8, runSpacing: 8)` au minimum.

### A4 — « Reprendre » ne dit ni quoi, ni où

> **Corrigé le 2026-09-30.** `detailPlayLabel` : « Lecture » / « Reprendre », suivi de l'épisode sur une série (« Reprendre S2 E4 »). Le pourcentage est remplacé par une barre et « 1h 15min restantes » (`formatRemaining`, partagé avec la carte « Reprendre la lecture »).

**Confiance : élevée.**

- Série : « REPRENDRE » (`show_detail_screen.dart:645-649`) lance l'épisode `resumeEp` sans le nommer. On ne sait pas si c'est S2 É4 ou S3 É1.
- Film : « REPRENDRE » + « 37 % visionné » en texte gris à côté. Un pourcentage se lit mal ; le temps restant ou la position se lit tout de suite.
- Trois libellés pour le même geste selon l'écran : « LECTURE », « REPRENDRE », « REGARDER » (`show_detail_screen.dart:657`).

**Correctif** : « Reprendre S2 · É4 », « Reprendre à 42:10 » ou « Reste 38 min », avec une fine barre de progression sous le bouton. Un seul verbe pour démarrer (« Lecture »), un seul pour continuer (« Reprendre »).

### A5 — La carte « Reprendre la lecture » cache ses actions

> **Corrigé le 2026-09-30.** Bouton « ⋯ » en haut à droite de la vignette : visible au survol et au focus, toujours visible au tactile.

**Confiance : élevée.**

« Marquer comme vu » et « Retirer » n'existent que par clic droit ou appui long (`widgets/global/continue_watching_card.dart:141-144`). Aucun signe visuel ne l'indique. Sur mobile, l'appui long est un geste que peu de gens essaient sur une affiche. Sans ça, un film abandonné reste en tête de l'accueil pour toujours.

**Correctif** : un bouton « ⋯ » visible au survol ou au focus sur desktop, et toujours visible (petit, dans un coin) sur tactile.

---

## B. Architecture de l'information

### B1 — Le même onglet porte deux noms

`main_shell.dart:457` : « Téléchargements » sur desktop ; `main_shell.dart:552` : « Hors ligne » sur mobile. Même écran, même index. Choisir un nom — « Téléchargements » est plus explicite, « Hors ligne » dit mieux pourquoi on y va — et l'appliquer partout, réglages compris (`settings_screen.dart:98`).

### B2 — Le menu compte mélange trois niveaux d'importance

> **Corrigé le 2026-09-30.** « Serveurs » et « Player Studio » retirés du menu (tous deux dans Paramètres), icônes sur toutes les entrées, rôle affiché sous le serveur.

`account_menu.dart:66-105`, dans l'ordre : changer de serveur · **Rejoindre une séance** · Serveurs · Paramètres · **Player Studio** · Connecter un appareil · Se déconnecter.

- « Serveurs » et « Paramètres » ouvrent le même `SettingsScreen` (le premier sur une section). Deux entrées pour une destination.
- « Player Studio » est un outil de personnalisation avancé, placé au même rang que les Paramètres. Il a sa place dans *Paramètres › Lecture › Interface du lecteur*, que le hint de la section annonce déjà (`settings_screen.dart:88`).
- « Rejoindre une séance » est une action contextuelle : sa vraie place est à côté de la lecture (fiche média, ou bannière quand une invitation arrive), le menu restant un raccourci secondaire.
- Le nom d'utilisateur est en tête mais sans avatar ni rôle ; sur un serveur partagé, afficher « Administrateur » / « Membre » éviterait des malentendus sur ce qu'on peut faire (lien direct avec A1).

**Proposition** : `[identité + serveur]` · `[changer de serveur]` · `Paramètres` · `Connecter un appareil` · `Se déconnecter`. Player Studio et Serveurs vivent dans Paramètres.

### B3 — ~~Réglages : dix-sept sections à plat~~ (retiré)

Erreur de lecture : la barre latérale sépare déjà « Mon espace » et « Administration », la seconde visible seulement avec un droit d'admin (`settings_screen.dart:416-426`, épinglé par `test/settings_screen_test.dart`). Rien à changer.

---

## C. Découverte et catalogue

### C1 — L'accueil n'a que trois rangées

> **En partie corrigé le 2026-09-30.** Rangée « À découvrir » avec la sélection aléatoire que le serveur envoyait déjà (`discovery_movies`/`discovery_shows`). Restent « Épisode suivant » et les rangées par genre, qui demandent le serveur.

`home_screen.dart:243-297` : Reprendre, Films récents, Séries récentes. Pour une médiathèque de quelques centaines de titres, c'est un accueil qui ne change que quand on ajoute des fichiers.

Données déjà disponibles côté client qui ne servent pas à la découverte : `genres` sur les détails TMDB (`models/models.dart:911`), collections (`CollectionSection`), acteurs.

**Pistes, par coût croissant** :
1. « Épisode suivant » : pour chaque série en cours dont le dernier épisode vu est fini, l'épisode d'après — la rangée la plus utile d'un lecteur de séries, distincte de « Reprendre ».
2. « Jamais vus » / « Ajoutés cette semaine ».
3. Rangées par genre (« Science-fiction », « Animation ») tirées au hasard à chaque ouverture.
4. « Parce que vous avez regardé X » à partir de `similarTitles` filtrés sur ce qui est dans la bibliothèque.

### C2 — Le catalogue n'a qu'un tri, et le tri alphabétique est faux en français

> **Tri corrigé le 2026-09-30** (`titleSortKey` : accents et articles). Filtres, rail A–Z et tri mémorisé restent à faire.

`movies_screen.dart:11,33-46` : tris Récents / A → Z / En cours, aucun filtre.

- `a.media.title.compareTo(b.media.title)` (ligne 37) compare les unités UTF-16 : **« Éternels » est rangé après « Zodiac »**, et une minuscule initiale après toutes les majuscules. Il faut une clé normalisée (minuscules, accents retirés, articles « Le/La/Les/L'/The » ignorés).
- Aucun filtre : genre, année ou décennie, non vus, 4K/HDR, durée. Sur une grille de 500 affiches, « un film de moins de 1 h 45 que je n'ai pas vu » est impossible.
- Pas de saut alphabétique (rail A–Z) sur une grille triée A → Z.
- Le tri choisi est un `setState` local (ligne 23) : il revient à « Récents » à chaque relance de l'app.

### C3 — La recherche ne trouve que des sous-chaînes exactes du titre

> **En partie corrigé le 2026-09-30.** `utils/search_match.dart` : insensible à la casse, aux accents et aux ligatures ; la ponctuation sépare les mots ; les mots de la requête peuvent venir dans n'importe quel ordre ; « spiderman » trouve « Spider-Man ». `LibraryProvider.searchCatalog` range par pertinence (titre exact, début de titre, début de mot, mots dans le désordre, sous-chaîne), puis par titre. Épinglé par `test/catalog_search_test.dart`. **Reste ouvert** : recherche par acteur ou titre original (données absentes du catalogue local) et raccourci clavier.

`providers/library_provider.dart:93-109` : `title.toLowerCase().contains(q)`, résultats triés par ordre alphabétique.

- **Pas d'insensibilité aux accents** : « amelie » ne trouve pas « Amélie », « pokemon » ne trouve pas « Pokémon ». C'est le premier réflexe de frappe sur un clavier de téléphone ou une télécommande.
- Pas de tri par pertinence : un titre qui *commence* par la requête devrait passer avant un titre qui la *contient*.
- Pas de recherche par acteur, réalisateur ou titre original, alors que la fiche personne existe (`person_detail_screen.dart`).
- Pas de raccourci clavier pour ouvrir la recherche sur desktop (`/` ou `Ctrl+K`) : aucun `LogicalKeyboardKey.slash`/`keyK` dans `app/lib`.

---

## D. Lecteur

### D1 — Raccourcis clavier desktop incomplets

> **Corrigé le 2026-09-30** (`screens/player/player_shortcuts.dart`), sauf `C`/`S` pour les sous-titres, qui demandent de toucher à la sélection de pistes du contrôleur.

`player_screen.dart:1376-1470` gère Espace, Entrée, flèches (±10 s, volume) et Échap. Il manque ceux que tout utilisateur de YouTube, Plex ou VLC tape par réflexe :

| Touche | Action attendue |
| --- | --- |
| `F` | Plein écran |
| `M` | Couper le son |
| `C` / `S` | Sous-titres suivants / désactiver |
| `N` / `Maj+N` | Épisode suivant |
| `J` / `L` | −10 s / +10 s |
| `0`–`9` | Aller à 0 %–90 % |
| `?` | Afficher l'aide des raccourcis |

L'aide `?` est importante en soi : les raccourcis existants ne sont affichés nulle part.

### D2 — Trois chromes de lecteur : c'est un coût permanent

Le lecteur a trois habillages (HUD par défaut, Modulaire, Onyx) plus Player Studio. Chaque correctif d'interaction doit être fait trois fois, et l'audit précédent le montre : le fondu et le scrubber ne sont corrects que dans l'un des trois (voir section E). Question produit à trancher : **faire d'Onyx le seul chrome par défaut**, garder Modulaire pour Player Studio, et retirer `PlayerHUDOverlay` (qui est encore monté quand aucun chrome fixe n'est choisi, `player_screen.dart:2740`, `:3112`, et utilise toujours `#007AFF` au lieu du token, `player_hud_overlay.dart:73`).

---

## E. Texte d'interface et typographie

### E1 — Capitales forcées sur les boutons

> **Corrigé le 2026-09-30** sur les fiches, le bandeau et les états vides/erreur.

« LECTURE », « REPRENDRE », « REGARDER », « PLUS D'INFOS », « RÉESSAYER », et `EmptyStateView` qui met tout libellé en capitales (`empty_state.dart:57,65`). Le brief est *Quiet Premium* : les capitales crient, se lisent plus lentement et ne correspondent à aucun autre bouton de l'app (« Se connecter », « Envoyer la demande »… sont en casse normale). Passer en casse de phrase partout.

### E2 — La dérive typographique s'aggrave

| Mesure | 2026-08-15 | 2026-09-30 |
| --- | --- | --- |
| `TextStyle(` locaux | 298 | **460** |
| Lectures `textTheme.` | 44 | 54 |
| `CircularProgressIndicator` | 36 | **65** |
| Squelettes de chargement | 0 | 0 |
| Tailles de police distinctes | 18 | 26 (dont 10.5, 11.5, 12.5, 13.5, 14.5) |
| Rayons `circular(n)` distincts | 21 | 20 |

Le finding 8 de l'audit fluidité (échelle typographique) n'a pas été traité et chaque nouvel écran ajoute ses propres tailles. Tant qu'il n'y a pas d'échelle nommée dans `AppTheme`, ce chiffre montera.

### E3 — Couleurs hors tokens restantes

> **Bleu corrigé le 2026-09-30** (41 occurrences → `AppColors.accent`) ; jaune de note → `AppColors.rating`. Restent `#00A4DC` et le violet des palettes au choix de l'utilisateur.

`#0A84FF` est écrit en dur 41 fois au lieu de `AppColors.accent` (surtout dans `screens/player_studio/`). Plus : `#00A4DC` (bleu Jellyfin, `player_screen.dart:3317,3344`), `#F5C518` (jaune IMDb, 3 endroits — acceptable si c'est la note IMDb, sinon `AppColors.warning`), `#BF5AF2` violet (`settings_ui.dart:699`, `player_layout.dart:31`) alors que le brief exclut le violet.

---

## F. État des findings ouverts des audits précédents

| Finding | Source | État au 2026-09-30 |
| --- | --- | --- |
| Owner de mouvement `AppMotion` | fluidité, plan 04 | **Fait** (`theme/app_motion.dart`) |
| Fondu symétrique des 3 chromes | fluidité 1–2, plan 05 | **Fait** (`screens/player/widgets/player_chrome_fade.dart`) |
| Scrubber qui suit le doigt | fluidité 3 | **Ouvert** : `modular_controls_layer.dart:425` et `control_chrome.dart:1767` émettent toujours à chaque drag |
| Rétroaction à l'appui (`Pressable`) | fluidité 4, plan 06 | **Fait** (`widgets/global/pressable.dart`) |
| Continuité affiche → fiche | fluidité 5 | **Partiel** : `pushPosterLaunch` existe mais n'est utilisé que depuis l'accueil (« Reprendre » et lecture du bandeau) ; les rangées Films/Séries récents, les fiches et la recherche utilisent `MaterialPageRoute` nu |
| Carrousel et « Réduire les animations » | fluidité 6 | **Fait** : plus d'avance automatique sous mouvement réduit ni après un appui au doigt |
| Squelettes de chargement | fluidité 9 | **En partie** : accueil, Films et Séries (`widgets/global/skeleton.dart`) |
| `minTouchTarget` consommé | fluidité 10 | **Ouvert** : zéro consommateur |

---

## Improve first

1. ~~**A1 — masquer les actions d'admin aux non-admins.**~~ Fait.
2. ~~**A3 + A4 — la rangée d'actions des fiches.**~~ Fait.
3. ~~**C3 — recherche insensible aux accents + tri par pertinence.**~~ Fait ; `foldForSearch` est réutilisable pour le tri A → Z de C2.
4. ~~**Plan 06 (`Pressable`)**~~ Fait.

Les points B1–B2 (onglet, menu compte) et C1 (rangées d'accueil) demandent une décision produit avant d'être planifiés.
