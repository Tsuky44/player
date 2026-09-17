# ADR-0025 — Ce que l'interface coûte, sous Windows

- **Statut :** proposé. Les quatre changements sont en place, la suite passe (410 tests) et le
  build Windows en release réussit. Les mesures avant/après sur une vraie session restent à faire
  (voir « À vérifier »).
- **Date :** 2026-09-18
- **Portée :** le verre du chrome (`control_chrome.dart`, `glass_chrome.dart`, le chrome du lecteur
  et la coquille), la police de l'application, l'ordre du démarrage dans `main.dart`, et le montage
  des onglets dans `MainShell`. Rien de la chaîne de lecture elle-même : ni mpv, ni le décodeur, ni
  la texture. L'ADR-0019 tient toujours ce terrain-là.

## Contexte

L'ADR-0019 a sorti la recopie de l'image décodée du chemin Windows, et l'ADR-0024 a fait taire le
flot d'erreurs d'accessibilité qui gelait l'arbre. Ce qui restait à regarder n'était plus la
lecture mais ce qui est posé dessus, et ce qui se passe avant qu'il y ait quoi que ce soit à poser.

Quatre choses ressortent de la lecture du code.

**Le verre se paie au nombre de panneaux.** Chaque `BackdropFilter` demande au moteur une copie de
ce qu'il recouvre, la floute, et la repose. Au-dessus d'un film, cette copie est refaite à chaque
image, parce que le fond change à chaque image. L'application en pose seize ; surtout, une
disposition modulaire (le Player Studio) en pose **un par contrôle placé**, et l'utilisateur peut
en placer une douzaine. Douze relectures de la même image, soixante fois par seconde.

**La police venait du réseau.** `GoogleFonts.manropeTextTheme` rapatrie Manrope depuis
fonts.gstatic.com au premier lancement, puis la relit depuis un cache disque à chacun des suivants.
Entre les deux, le texte s'affiche dans la police du système puis saute. Pour un client de serveur
média privé, qui doit ouvrir un film téléchargé sans que rien ne réponde, dépendre de Google pour
écrire un titre est une dépendance de trop.

**Le démarrage posait ses questions une par une.** Dix initialisations enchaînées par `await` —
préférences, version du paquet, fenêtre, trousseau, capacités de l'appareil — dont une seule
dépendait de la réponse d'une autre. Leurs allers-retours s'additionnaient devant l'écran de
démarrage.

**La coquille montait cinq écrans pour en montrer un.** L'`IndexedStack` de `MainShell` garde ses
cinq onglets vivants, ce qui rend le changement d'onglet instantané. Le prix en était caché :
`MoviesScreen` et `ShowsScreen` construisent chacun la grille de toute la médiathèque, et films,
séries et demandes lancent chacun leur requête depuis `initState`. Soit quatre écrans et trois
appels réseau derrière l'accueil, pendant que l'accueil attend sa réponse sur la même connexion.

## Décision

### 1. Un seul fond partagé pour le verre d'un même écran

`BackdropGroup` (Flutter 3.35+) donne une clé commune à plusieurs `BackdropFilter.grouped` : le
moteur ne lit alors le fond **qu'une fois** et sert le même à tous. Le lecteur, la toile du studio
et la coquille ouvrent chacun leur groupe ; le verre posé *sur* le film ou *sur* la page le rejoint.

Ce qui vient **par-dessus** ce chrome n'y entre pas : le menu de réglages, la fiche du média, le
panneau des épisodes, la recherche du catalogue. Un panneau du groupe lit l'image telle qu'elle
était avant que le groupe ne commence à peindre : deux verres du même groupe qui se recouvrent
donneraient le résultat d'un seul. Ceux-là doivent flouter le chrome qu'ils couvrent, donc garder
leur propre lecture. La frontière est celle-là, et `test/backdrop_group_test.dart` la tient, des
deux côtés.

`BackdropFilter.grouped` sans groupe au-dessus se comporte exactement comme un flou ordinaire. Un
widget de verre reste donc utilisable hors du lecteur, sans condition à écrire chez lui.

### 2. La police est dans le paquet

Les six graisses de Manrope que l'application demande (300 à 800) sont sous `assets/fonts`, et
`google_fonts` a disparu des dépendances. La famille est posée sur le `ThemeData` et non sur le
seul `textTheme`, pour qu'un `TextStyle` écrit à la main en hérite lui aussi. La licence OFL est
embarquée et déclarée à `LicenseRegistry`, paresseusement — le fichier n'est lu que si quelqu'un
ouvre la page des licences.

Des fichiers statiques plutôt que la police variable : une graisse, un fichier, aucune question sur
ce que l'axe `wght` donne sur telle version du moteur. Cela coûte 570 Ko dans le paquet.

### 3. Le démarrage pose ses questions ensemble

Seul `TvMode.initialize()` reste devant : le profil de lecture a besoin de sa réponse, et l'écran
de connexion d'un téléviseur n'est pas celui d'un ordinateur. Tout le reste part ensemble et se
rejoint sur un `Future.wait`. C'est la plus lente qui donne le tempo, au lieu de la somme.

### 4. Les onglets non visités arrivent plus tard

Seul l'onglet affiché est monté à la première image. Les autres le sont trois secondes après — le
délai de `PlayerEnginePool.prewarm`, et pour la même raison : occuper un moment creux plutôt que
disputer le démarrage à ce que l'utilisateur regarde. Un onglet choisi avant son tour se monte
immédiatement.

Une fois montés, ils le restent : c'est ce qui rend le changement d'onglet instantané, et c'était la
seule raison de les monter tôt. Elle est gardée ; ce qui est retiré, c'est la contention.

### 5. Deux petites dettes, au passage

Le réarmement du compte à rebours qui masque le chrome est espacé de 200 ms. Une souris de jeu
rapporte jusqu'à mille positions par seconde, et chacune détruisait puis reconstruisait un `Timer`.
Le compte à rebours dure quatre secondes : le décaler de deux dixièmes ne se voit pas.

`AppTheme.dark` était un getter qui reconstruisait `ThemeData` — et en rendait une *autre instance*,
ce qui fait reconstruire tout ce qui lit `Theme.of(context)`. Il est construit une fois.

## Ce qui n'a pas été touché, et pourquoi

- **Le chrome se reconstruit quatre fois par seconde** quand il est visible (`_refreshPositionUi`).
  Faire passer la position par un `ValueNotifier` limiterait la reconstruction à la barre de
  progression, mais c'est une refonte d'un fichier de trois mille lignes pour quelques
  millisecondes à 4 Hz — quand le flou, lui, se repayait soixante fois par seconde. L'un valait le
  risque, l'autre non.
- **Impeller sous Windows.** Le moteur Vulkan se demande par variable d'environnement dans
  `main.cpp`. Il changerait la façon dont la texture de media_kit est présentée, et rien ici ne
  permet de dire si le pont ANGLE/D3D11 y survit. À essayer avec une mesure en main, pas en
  confiance.
- **Les options mpv.** Tailles de cache, `hwdec`, rognage, synchronisation : réglées et documentées
  par les ADR-0019 et 0021 à 0023. Les toucher sans banc d'essai serait deviner.

## Conséquences

- Un `BackdropFilter` nu ajouté au chrome du lecteur retombe silencieusement sur sa propre lecture
  du fond. `test/backdrop_group_test.dart` refuse la régression, fichier par fichier.
- Une police à ajouter se déclare dans le `pubspec`, et le test vérifie que chaque fichier déclaré
  existe — une déclaration morte ferait retomber l'interface sur la police du système sans le dire.
- Le premier passage sur Films ou Séries, dans les trois premières secondes, montre maintenant son
  indicateur de chargement. Après, plus jamais.
- `main()` ne dit plus l'ordre dans lequel les initialisations finissent. Une dépendance nouvelle
  entre deux d'entre elles doit être écrite, pas supposée.

## À vérifier

- Sur une vraie session Windows, chronomètre en main : la première image de l'application, et la
  charge GPU pendant qu'un film 4K joue avec une disposition modulaire de huit contrôles à l'écran
  — avant et après le groupe.
- Que le verre a la même allure : le chrome sur le film, l'en-tête de la coquille au défilement, et
  surtout un menu de réglages ouvert **par-dessus** le chrome, qui doit continuer de le flouter.
- Le studio, où l'utilisateur peut délibérément superposer deux contrôles : c'est le seul endroit où
  deux verres d'un même groupe peuvent se recouvrir.
