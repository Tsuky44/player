# ADR-0008 — Sur téléviseur, le chrome affiché a toujours une commande sélectionnée

- **Statut :** accepté
- **Date :** 2026-08-26
- **Portée :** le pilotage du lecteur à la télécommande sur Android TV. Remplace la règle de
  l'ADR-0003 §4 (« le lecteur détient le focus, donc les flèches parcourent le film ») et amende
  l'ADR-0006 §1 et §4, qui l'implémentaient.

## Contexte

L'ADR-0003 §4 confiait deux rôles aux quatre flèches, départagés par qui détient le focus : le
lecteur l'a par défaut, donc les flèches parcourent le film ; OK le donne à la barre de contrôle,
et de là les mêmes flèches marchent entre les boutons.

Le modèle est cohérent sur le papier. À l'usage il produit **deux états que rien ne distingue à
l'écran** : même image, même barre de progression affichée — mais dans l'un rien n'est entouré et
gauche/droite avancent dans le film, dans l'autre un bouton est entouré en bleu et gauche/droite
changent de bouton. Lequel des deux est en cours dépend de *comment* le chrome est apparu :

- appelé par OK, le focus part sur lecture/pause : quelque chose est sélectionné ;
- appelé par un déplacement dans le film, par la reprise après une pause, par la fermeture d'un
  menu ou simplement à l'ouverture du film, `_showControlsTransient()` affiche la barre **sans
  toucher au focus** : rien n'est sélectionné.

C'est le défaut rapporté mot pour mot : « des moments je vois où je suis car c'est surligné en
bleu, et d'autres fois rien n'est sélectionné et les flèches avancent ou reculent dans le temps ».
Ce n'est pas un focus perdu : c'est le modèle lui-même, dont l'état courant n'est pas lisible.

Le lecteur d'Emby, pris comme référence, n'a pas ce partage. Son OSD affiché a toujours une
commande sélectionnée, et c'est la barre de progression.

## Décision

**Sur téléviseur, chrome à l'écran ⇒ une commande est entourée. Sans exception.**

### 1. La barre de progression est le point d'atterrissage

Le lecteur lui fournit un `FocusNode`, comme il le faisait pour lecture/pause. Elle est choisie
parce qu'elle **préserve le geste** : gauche et droite y reculent et avancent de 10 s, exactement
ce qu'elles faisaient sur le film. Rien ne change sous la main de l'utilisateur — ce qui change,
c'est que l'écran dit maintenant quelle commande répond.

OK sur la barre déclenche lecture/pause : c'est l'appui le plus fréquent, et il ne doit pas
imposer une descente vers la rangée de boutons.

### 2. Un seul point de passage : `_ensureRemoteInChrome()`

Toutes les routes qui lèvent le chrome passent par `_showControlsTransient()`. C'est donc là que
l'invariant est tenu, et non dans chacun des appelants. La méthode ne fait rien hors mode TV, rien
si le chrome est baissé, et rien si la télécommande est **déjà** sur une commande — sans quoi
chaque déplacement dans le film ramènerait l'utilisateur sur la barre depuis le bouton où il se
trouvait.

L'écouteur du nœud du lecteur (ADR-0006 §4) l'appelle aussi : quand le focus revient d'un menu ou
d'un panneau qui se ferme, il ne s'arrête plus sur le lecteur si le chrome est encore affiché.

### 3. Les flèches ne parcourent plus le film à l'aveugle

Chrome baissé, n'importe laquelle des quatre flèches lève le chrome et pose l'anneau sur la barre —
et ne déplace pas la lecture. L'appui suivant, lui, déplace : la même touche, avec l'écran qui
montre ce qu'elle fait.

De même OK ne bascule plus lecture/pause depuis le lecteur en mode TV : il lève le chrome. La
bascule vient de l'appui suivant, sur la barre.

Hors mode TV rien ne bouge : flèches gauche/droite pour parcourir, haut/bas pour le volume, OK et
espace pour lecture/pause.

## Conséquences

- Un appui de plus pour le premier déplacement dans le film depuis un chrome baissé. C'est le prix
  de l'invariant, et c'est le comportement d'Emby.
- Retour garde la pile de l'ADR-0006 §5 (menu, panneau, barre, film) ; comme le chrome affiché
  implique désormais que la télécommande est dessus, le premier Retour baisse le chrome et le
  second quitte le film — ce que faisait déjà le modèle, mais de façon prévisible cette fois.
- Un film en pause garde son chrome (ADR-0006), donc garde aussi son anneau : la télécommande reste
  posée sur la barre au lieu de retomber sur un lecteur invisible.
- Le nœud de lecture/pause reste fourni et reste le repli quand un chrome n'expose pas de barre
  focusable.
