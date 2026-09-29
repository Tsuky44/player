# ADR-0039 — La force du geste sur le trackpad de l'Apple TV, et un seul défilement par pas

- **Statut :** accepté, écrit sous Windows. Le Dart est analysé et testé ; **aucun geste n'a encore
  été fait sur une vraie Siri Remote**, et les seuils de vitesse sont des estimations à régler.
- **Date :** 2026-09-29
- **Portée :** la navigation à la télécommande sur tous les téléviseurs (`tv/tv_focus_scroll.dart`,
  `tv/tv_key_repeat.dart`, `tv/tv_focus.dart`, la politique de parcours posée dans `main.dart`) ; le
  trackpad de la Siri Remote sur Apple TV (`tv/touchpad_motion.dart`, `tv/tv_touchpad.dart`,
  `tv/siri_remote_touches*.dart`) ; l'avance rapide du lecteur (`playback/remote_seek.dart`).
- **Prolonge :** [ADR-0028](0028-cible-apple-tv.md) (la cible Apple TV),
  [ADR-0006](0006-chrome-du-lecteur-a-la-telecommande.md) (le lecteur à la télécommande).

## Contexte

Deux reproches sur la navigation au téléviseur, un pour tous et un propre à l'Apple TV.

**Chaque flèche faisait défiler deux fois.** Le parcours directionnel de Flutter demande le focus
puis appelle `Scrollable.ensureVisible` avec une durée nulle : la rangée *saute* pour montrer la
cible au bord de l'écran. À la frame suivante, `TvFocusable` anime la même rangée pour centrer la
carte. Chaque pas donnait donc un bond puis une glissade, et l'œil perdait l'affiche qu'il suivait.
Le test `tv_focus_scroll_test.dart` mesure le bond : 300 px d'un coup avec le rappel par défaut.

**Le trackpad de la Siri Remote n'était lu que comme un pavé directionnel.** Le moteur de
flutter-tvos fait de chaque glissé une flèche. Mais une flèche est la même que le doigt ait
effleuré la surface ou l'ait balayée d'un coup sec : une rangée de quarante films se traversait à
coups de pouce répétés, et avancer de dix minutes dans un film demandait une rafale de glissés.

## Décision

### 1. Un seul défilement par pas, toujours animé

`main.dart` pose au-dessus du `Navigator` (qui en hérite) une `ReadingOrderTraversalPolicy` dont le
rappel est `TvFocusScroll.requestFocus`. Sur un téléviseur, il demande le focus et :

- ne fait **rien** de plus quand la cible est un `TvFocusable`, qui se place lui-même ;
- fait sinon un `ensureVisible` **animé** (un bouton Material dans une liste).

`TvDirectionalFocusAction` (gauche et droite) passe par le même rappel. La durée vient d'un seul
endroit, `TvFocusScroll.durationFor`, et respecte « réduire les animations » (`AppMotion.move`).
Elle raccourcit à `AppMotion.track` (90 ms) quand les pas s'enchaînent : ce jeton est hors de la
plage 180–280 ms parce qu'il n'est pas une transition mais un suivi, et doit finir avant le pas
suivant (`TvKeyRepeat.repeatInterval`, 110 ms). Hors téléviseur, le rappel est celui de Flutter.

### 2. La vitesse du doigt, lue à côté des flèches du moteur

On ne remplace pas les flèches du moteur : on les **complète**. Le paquet `flutter_tvos` fait la
poignée de main `configure` sans laquelle le moteur ne transmet pas les points du doigt, puis les
livre bruts. `TouchpadMotion`, un modèle pur testé à la milliseconde, garde les points des
100 dernières ms et en tire une vitesse.

Écartée : prendre la main entière sur le trackpad en neutralisant les flèches du moteur. Il aurait
fallu reconnaître puis avaler les flèches synthétisées pendant un geste, sans avaler celles d'un
clic sur le bord du pavé, et fabriquer les nôtres. Le code du moteur n'est pas publié ; ce tri
aurait reposé sur des suppositions invérifiables sans appareil. Compléter a une propriété que
remplacer n'a pas : si le flux tactile n'arrive jamais, tout se comporte exactement comme avant.

### 3. L'accélération et l'élan, seulement dans les rangées horizontales

- **Accélération.** Une flèche qui arrive pendant un glissé vif dans son sens vaut 2 ou 3 pas
  (seuils 8 et 13 unités de surface par seconde). Une flèche sans doigt en mouvement depuis 150 ms
  (pavé, manette, app Remote de l'iPhone) vaut toujours un pas, et un clic n'est jamais accéléré.
- **Élan.** Un doigt levé à plus de 10 u/s laisse la rangée continuer, un pas de plus tous les
  3 u/s au-delà, 6 au plus, à intervalles qui s'allongent (60 ms, ×1,15). Poser le doigt, cliquer
  ou appuyer sur une autre touche l'arrête ; le bout de la rangée aussi.

Les deux ne valent que si l'élément focalisé est dans un `Scrollable` **horizontal** : une rangée
d'affiches. Dans une liste verticale, une barre de boutons ou un menu, un pas reste un pas. Les
rangées du chrome du lecteur (`TvFocusRows`) gèrent leurs flèches elles-mêmes et ne sont jamais
accélérées.

*Réglage après le premier essai sur une Apple TV (2026-09-29).* La première version accélérait
aussi à la verticale, dès 4 u/s et jusqu'à 4 pas, avec un élan de 12 éléments : « trop fort sur
l'accueil et dans les menus ». Un glissé vers le bas sautait des rangées entières. La verticale ne
s'accélère plus, et les seuils horizontaux ont doublé.

### 4. La barre de lecture suit le doigt

La première version multipliait le pas des flèches (10 s) par l'accélération : « pas assez fort
suivant le slide ». Le moteur ne tire qu'une ou deux flèches d'un glissé, tôt dans le geste, et
leur nombre ne dit presque rien de la longueur ni de la vitesse du geste.

Le lecteur écoute donc directement les déplacements du doigt (`TvTouchpad.addMoveListener`) là où
gauche et droite font avancer le film : sur le film lui-même ou sur la barre de lecture. Chaque
déplacement avance la cible de `RemoteSeek.scrub` : 20 s de film par unité de surface (un
demi-trackpad), multipliées par le carré de la vitesse au-delà de 2 u/s, comme l'accélération d'une
souris. Un demi-trackpad lent avance de 20 s ; le même geste quatre fois plus vif, de 5 min 20.
Une unité ne vaut jamais plus d'un demi-film. Pendant un glissé, les flèches que le moteur en tire
sont ignorées par l'avance rapide, qui les compterait deux fois ; le pavé directionnel garde ses
pas de 10 s, 30 s puis 60 s (`RemoteSeek`, extrait de `player_screen.dart`).

## Conséquences

- **Les seuils sont à régler sur une Apple TV.** Ce sont des constantes nommées de
  `TouchpadMotion` et `TvTouchpad`. Si un geste posé accélère, monter `_boostSpeeds` ; si l'élan
  part trop loin, baisser `_maxFlingSteps` ou monter `_flingSpeed`. Pour la barre de lecture,
  `_scrubSecondsPerUnit` règle le geste lent et `_scrubKneeSpeed` le moment où la vitesse compte
  (`RemoteSeek`).
- **Le réglage du moteur n'est pas touché** (`TvRemoteConfig` par défaut). Si un glissé léger
  produit plusieurs flèches à lui seul, `continuousSwipeMoveThreshold` est le prochain levier.
- **Android TV** profite du point 1 seulement : sa télécommande n'a pas de surface tactile.
- **Nouvelle dépendance** `flutter_tvos`, importée derrière un import conditionnel : le web n'en
  compile rien, et les autres plateformes n'en embarquent pas de code natif (le paquet ne déclare
  que tvOS).
