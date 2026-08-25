# ADR-0006 — Le chrome du lecteur piloté à la télécommande

- **Statut :** accepté
- **Date :** 2026-08-25
- **Portée :** le chrome du lecteur sur Android TV — barre de contrôle, menus qu'elle ouvre,
  panneau des épisodes, et la disparition automatique du chrome. Prolonge l'ADR-0003 §4, qui
  posait la règle sans que le chrome puisse l'honorer.

## Contexte

L'ADR-0003 §4 fixe la règle du lecteur à la télécommande : le lecteur détient le focus, donc les
flèches parcourent le film ; OK donne le focus à la barre de contrôle, Retour le rend. La règle
était juste et la barre ne pouvait pas la tenir.

Le chrome Emby ne contient **aucun widget focusable**. Ses boutons sont des `GestureDetector`
enveloppés d'un `MouseRegion` : ils prennent le clic et le survol, rien dans cette pile ne demande
le focus. Le seul widget focusable de tout le chrome était le `Slider` de volume en haut à droite.
Trois symptômes en découlaient, qui n'en font qu'un :

- **OK menait au curseur de volume et nulle part ailleurs.** `_enterControlBar()` demandait le
  focus suivant ; le seul candidat était ce curseur, et la croix directionnelle n'avait ensuite
  aucun voisin où aller.
- **Les flèches haut/bas réglaient un volume qui n'est pas celui du téléviseur.** La seule
  commande qui répondait à la télécommande était donc celle qui ne servait à rien dans un salon.
- **Le chrome ne disparaissait plus jamais.** `_remoteBrowsingControls` valait « mode TV et le
  lecteur n'a pas le focus principal », et le compte à rebours de masquage se **ré-armait** dans
  cet état. Une fois le focus posé sur le curseur — ou perdu n'importe où hors du lecteur — la
  condition restait vraie pour toujours : la barre restait à l'écran sans que personne ne touche
  la télécommande, et les flèches ne revenaient jamais au film.

S'y ajoutait un piège plus discret : le chrome masqué n'était retiré que du test de pointage
(`IgnorePointer`). Ses boutons restaient focusables, donc le focus pouvait être posé sur une barre
que personne ne voit.

## Décision

### 1. Chaque commande du chrome est focusable, par le mécanisme déjà en place

`_EmbyIconButton` est enveloppé dans `TvFocusable` — le même widget que les vignettes du catalogue,
avec le même anneau d'accentuation et le même agrandissement au focus. Le `GestureDetector` interne
est conservé tel quel : la souris et le doigt gardent exactement le chemin qu'ils avaient.

La même enveloppe est posée sur les contrôles placés de la mise en page modulaire, qui souffraient
du même défaut pour la même raison.

Le bouton lecture/pause reçoit un `FocusNode` fourni par le lecteur : c'est là que la télécommande
atterrit en entrant dans la barre. Sans lui, le point d'entrée serait l'ordre de parcours, qui
désigne ce qui se trouve en premier dans l'arbre — le bouton Retour, en haut à gauche, à l'opposé
de la barre que l'utilisateur vient d'appeler.

### 2. Pas de volume dans le chrome d'un téléviseur

Le curseur de volume est retiré du chrome en mode TV, et les flèches haut/bas n'y touchent plus :
les deux mènent désormais à la barre de contrôle. Un téléviseur a son propre volume sur sa propre
télécommande, souvent relayé à un ampli ; un second réglage, en aval du premier, produit deux
niveaux à accorder pour un seul son.

C'est la décision déjà prise pour la luminosité : `ScreenBrightnessControl` se déclare non
supporté sur TV — un téléviseur règle son rétroéclairage depuis sa propre télécommande — et la
barre de luminosité est absente du chrome pour cette raison. Le volume tombe sous la même règle.

### 3. La disparition du chrome ne se ré-arme plus indéfiniment

Le compte à rebours ne se relance plus tout seul quand la télécommande est sur la barre. Il est
relancé par **les appuis de touche**, comme un mouvement de souris relance celui du pointeur.
Quand il arrive à son terme alors que la télécommande n'a rien fait pendant quatre secondes, la
barre s'efface **et rend le focus au lecteur** : sans cela, la barre partirait en emportant le
curseur, et l'appui suivant tomberait sur un bouton que personne ne voit.

`_remoteBrowsingControls` distingue maintenant deux états que l'ancienne condition confondait :
« une commande du chrome a le focus » (le nœud du lecteur a `hasFocus` mais pas
`hasPrimaryFocus` — le chrome vit dans son sous-arbre) et « le focus a quitté le lecteur
entièrement ». Le second n'est pas une navigation dans la barre ; c'est une anomalie, et un
écouteur sur le nœud du lecteur le récupère — sauf si un menu est ouvert, ou si la route est en
train d'être quittée, deux cas où le focus est là où il doit être.

Le chrome masqué passe dans `ExcludeFocus`, pour la raison qui a valu la même enveloppe aux onglets
cachés du shell (ADR-0003 §3) : le parcours du focus lit l'arbre de widgets, pas ce qui est à
l'écran.

### 4. Les menus du lecteur sont des surfaces atteignables

Les menus (réglages, sous-titres, pistes, fiche) sont des `OverlayEntry`, pas des routes. Rien ne
leur donne le focus et Retour ne les ferme pas : à la télécommande, un menu ouvert était donc
inatteignable, et Retour quittait le film avec le menu encore affiché.

Ils passent tous par `_insertPlayerPopup`, qui leur prête un `FocusScope` où la télécommande est
conduite, et qui enregistre leur fermeture là où le traitement de Retour du lecteur la trouve.
Retour déroule désormais une pile explicite : menu, puis panneau des épisodes, puis barre de
contrôle, puis le film. Le panneau des épisodes prend son propre `FocusScope` pour la même raison.

Un seul menu à la fois : chacun couvre l'écran de son propre voile de fermeture, donc celui du
dessous serait de toute façon hors d'atteinte.

## Conséquences

- Les commandes du chrome deviennent focusables **sur toutes les plateformes**, pas seulement sur
  TV — un utilisateur clavier sur desktop en hérite, comme pour les vignettes du catalogue. Seuls
  l'agrandissement au focus et la prise de focus automatique restent réservés au mode TV.
- Le volume interne reste réglable sur TV par les touches média, et le mixage reste celui du
  serveur : c'est l'affichage et les flèches qui disparaissent, pas la piste audio.
- La barre de progression n'est pas focusable. Se déplacer dans le film est le métier des flèches
  quand le lecteur a le focus — c'est-à-dire Retour, puis gauche/droite — et non un arrêt de plus
  dans le parcours de la barre.
- Un film **en pause garde son chrome** : le compte à rebours s'arrête là. Il ne se relance qu'à la
  reprise de la lecture.
