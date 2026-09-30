# Audit « premium » — ce qui fait cheap dans Onyx

Écrit le 2026-09-30, contre `512688c8` plus l'arbre de travail.

**Méthode.** Contrairement aux trois audits précédents, celui-ci part de l'image. Aucun serveur ne tournait en local : les écrans ont été rendus dans des tests Flutter (`matchesGoldenFile`) avec la police Manrope embarquée, les icônes Material et de fausses affiches servies par un petit serveur HTTP local, en 1440 × 900 et 390 × 844. Le banc de captures était temporaire ; il a été retiré.

Complète [audit-ui.md](audit-ui.md) (tokens), [audit-fluidite.md](audit-fluidite.md) (mouvement) et [audit-ux.md](audit-ux.md) (parcours).

La question posée : *qu'est-ce qui empêche l'app de paraître haut de gamme ?* Réponse courte : pas la palette ni la police, qui sont justes, mais une accumulation de réflexes Material par défaut et de répétitions. Onyx avait l'air d'une app Android bien réglée, là où Apple TV, Infuse ou Plex ressemblent à une boutique de films.

---

## Corrigé dans cette passe

### 1. Le bandeau d'accueil étirait une affiche portrait

Le fond du bandeau était l'**affiche** du film (portrait 2:3) recadrée en 16:9 : agrandie jusqu'au flou, visages coupés, et le titre de l'affiche parfois visible derrière le titre en texte. C'était le premier écran de l'app, en plein écran.

- Le fond vient maintenant de la fiche TMDB (`backdrop_url`, paysage), et le titre est remplacé par le **logo** du film quand il existe (`MediaLogoDisplay`). Chargés via `MediaDetailsCache`, déjà utilisé par les fiches. `widgets/global/hero_banner.dart`.
- L'année était écrite deux fois (« 2010 · 2010 ») : `hero_slides.dart` l'ajoutait au sous-titre que le bandeau précédait déjà de l'année.
- Une marche visible séparait le bas du bandeau de la première rangée : le voile latéral, en noir pur, était peint *par-dessus* le fondu vertical vers la couleur de la page. Les deux voiles fondent désormais vers `AppColors.background`, le vertical en dernier.
- Le synopsis courait sur toute la largeur de l'écran : la limite de 560 px était posée sous un `Positioned` qui imposait sa largeur. Un `Align` la rend effective.
- Capitales (« REPRENDRE », « PLUS D'INFOS ») → casse de phrase ; indicateurs de page alignés sur le texte au lieu d'être centrés sous un contenu calé à gauche ; le carrousel ne défile plus seul sous « Réduire les animations » ni après un appui au doigt.

### 2. L'ondulation Material partout

Chaque bouton, carte et ligne peignait l'onde grise de Material : l'idiome Android, qui sur fond charbon se lit comme une tache. `splashFactory: NoSplash.splashFactory` dans `AppTheme` ; les boutons gardent leur voile d'appui. Les cartes répondent à l'appui par une échelle de 0,97 (`widgets/global/pressable.dart`, plan 06), y compris « Reprendre la lecture », qui ne répondait à rien.

### 3. Les menus en Material 3 brut

Teinte de surface M3, rayons différents selon l'écran, couleurs posées écran par écran. Un seul thème pour `PopupMenu`, `MenuAnchor`, `DropdownMenu` et les infobulles : fond élevé, filet clair, rayon 14, ombre ample.

### 4. Les fiches film et série

| Avant | Après |
| --- | --- |
| Métadonnées en boîtes grises à liseré (« 2024 » « 2h46min » « ★ 8.3 ») | Ligne de texte à points médians, note avec une virgule (`widgets/global/detail_metadata.dart`) |
| Qualité du fichier invisible avant de descendre | Badges de jaquette dans l'en-tête : **4K · Dolby Vision · Dolby Atmos · 7.1** (`techBadgesFor`) |
| « Média sur le serveur » en tête de page, avant le synopsis | « Informations techniques », en bas de page |
| Synopsis affiché deux fois, l'un sous l'autre | Répété en entier seulement s'il est coupé dans l'en-tête (`DetailBackdropHeader.overviewTruncated`) |
| Genres en pilules bleues (couleur d'accent sur du non-cliquable) | Pilules neutres |
| Titres de section en 22 px extra-gras | 19 px demi-gras (`detailSectionTitleStyle`) |
| « Marquer vu » souligné + trois icônes nues | Quatre disques de verre de 44 px identiques |
| Audio : « Français (Français 5.1 5.1) » | « Français (5.1 Dolby Digital+) » |
| Surtitre « Film » en bleu | En capitales espacées grises, comme le bandeau |

### 5. Les épisodes

- **Trois coches vertes par ligne** (à gauche, à droite, et « Vu » en vert sous le titre) → une seule, blanche, à droite ; à gauche une coche grise discrète.
- « 37 % visionné » → « 30 min restantes ».
- Menu déroulant des saisons → **onglets** (`screens/library/widgets/season_tabs.dart`), qui montrent d'un coup combien de saisons existent et lesquelles manquent.
- « Télécharger les non vus » flottait au milieu de la ligne : un `Flexible` et un `Spacer` se partageaient l'espace.

### 6. Catalogues et chargements

- En-tête Films/Séries sur trois lignes (titre, boîte de tri Material seule à droite, compte en dessous) → une ligne : titre, compte, tri discret (`screens/library/widgets/catalog_header.dart`).
- Tri A → Z : « Éternels » après « Zodiac » → clé normalisée qui ignore accents et articles (`titleSortKey`).
- Spinner plein écran puis grille entière d'un coup → **squelettes** qui tiennent la mise en page (`widgets/global/skeleton.dart`) sur l'accueil, Films et Séries.

### 7. Navigation mobile

Barre d'onglets en voile blanc à 5 %, plus légère que n'importe quel menu, avec l'onglet actif en bleu d'accent → verre sombre dense, icônes creuses/pleines, sélection en blanc.

### 8. Le reste

- États d'erreur : icône rouge de 64 px (une alarme au milieu d'une page de films) → nuage gris ; boutons en casse de phrase.
- Lecteur : un seul fondu pour les trois habillages (`player_chrome_fade.dart`, plan 05) ; raccourcis `K J L F M N 0–9` et `?` pour les afficher (`player_shortcuts.dart`).
- Menu du compte : « Serveurs » et « Player Studio » retirés (déjà dans Paramètres), icônes sur toutes les entrées, rôle affiché (« Administrateur » / « Membre »).
- Accueil : rangée **« À découvrir »** avec les titres que le serveur tire déjà au hasard (`discovery_movies`/`discovery_shows`) et que l'app n'utilisait que pour le bandeau.
- 41 `Color(0xFF0A84FF)` codés en dur → `AppColors.accent` ; nouveau token `AppColors.rating` pour l'étoile des notes.

---

## Reste à faire, par impact

1. **Icônes.** Le jeu Material (clap de cinéma, téléviseur, « + » cerclé) est le marqueur « app Android » le plus visible qui reste, dans la barre d'onglets surtout. Un jeu au trait fin et régulier (Lucide ou Phosphor, ou des icônes dessinées dans `brand/`) changerait la perception d'un coup. Demande une dépendance, donc une décision.
2. **La marque.** « ONYX » en capitales espacées à côté d'un disque « play » générique se lit comme un gabarit. `brand/` contient un wordmark vectorisé : le header devrait l'utiliser.
3. **Vignettes d'épisodes dans « Reprendre ».** Un épisode y apparaît avec l'affiche de la série ; les apps de référence montrent l'image de l'épisode en 16:9, titre de l'épisode dessous. `ContinueWatchingCard` a déjà deux cibles de tap ; c'est surtout un format de carte.
4. **Transitions de page.** Les fiches s'ouvrent avec la `MaterialPageRoute` de l'OS (zoom sous Windows, glissement sous macOS) : le web n'a pas la même navigation selon le système. Une transition maison unique, et la continuité affiche → fiche (`Hero`), cf. audit fluidité, finding 5.
5. **Échelle typographique.** 460 `TextStyle` construits sur place, 26 tailles (dont 10.5, 11.5, 12.5, 13.5, 14.5). Rien ne choque isolément, mais c'est ce qui empêche deux écrans d'avoir exactement la même voix. Chantier à mener par lots d'écrans, cf. audit fluidité, finding 8.
6. **Onglets du header desktop en pilule grise pleine.** Un soulignement ou un point, comme le prévoit `PROJECT_DESIGN.md` §8.
7. **Barre du haut sur mobile (Films, Séries).** Recherche et avatar flottent sans fond : les affiches défilent dessous. Un verre qui apparaît au défilement, comme sur l'accueil desktop.
8. **Cibles de 32 px** dans le header (`GlassIconButton`) et **scrubbers modulaires** qui suivent le décodeur plutôt que le doigt (audit fluidité, findings 3 et 10).
