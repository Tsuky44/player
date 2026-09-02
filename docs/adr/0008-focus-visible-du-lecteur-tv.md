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

## Amendement (2026-08-27) — un champ de saisie est un mur sur le chemin du focus

Le même raisonnement vaut pour les champs de texte, et il coûtait plus cher que prévu.

Sur Android, un champ qui prend le focus fait ouvrir le clavier virtuel. Sur un téléviseur ce
clavier est plein écran. Un champ posé sur le chemin du parcours devient donc infranchissable : la
croix directionnelle le traverse, le clavier s'ouvre par-dessus tout, et **ce qui se trouve après
lui est inatteignable**. Dans l'en-tête, la barre de recherche est juste avant l'avatar du compte :
les Paramètres étaient donc hors d'atteinte à la télécommande. L'onglet Demandes avait le même
défaut, son champ étant le premier arrêt de l'écran.

`TvDeferredKeyboard` fait de ces champs des **boutons** : hors du parcours tant que personne n'a
appuyé sur OK, et de nouveau hors du parcours dès que le clavier se referme — sinon le passage
suivant le rouvrirait de lui-même. Le focus revient alors sur le champ-bouton, pour ne laisser la
télécommande nulle part.

Hors téléviseur, le widget est transparent : le champ prend le focus au clic, comme avant.

**La règle vaut pour tous les champs, pas pour ceux qui gênaient.** Les Réglages en comptent sept,
le formulaire de connexion quatre, les filtres de demandes trois : parcourir cet écran à la
télécommande ouvrait et refermait le clavier à chaque arrêt. Les vingt champs de l'app passent donc
par ce widget, et **un test refuse la construction si un champ nu réapparaît** — avec une liste
d'exceptions courte et motivée, parce que la prochaine occurrence viendra d'un fichier que personne
n'aura relu.

Deux détails que la migration a fait sortir :

- Enchaîner deux champs ne peut plus se contenter de demander le focus au suivant : il est hors du
  parcours tant que personne n'a réclamé son clavier. Le formulaire de connexion, dont l'ADR-0003
  documente le chaînage, appelle donc `requestKeyboard()` sur le champ suivant.
- La méthode ne s'appelle **pas** `activate` : `State` en a déjà une, que Flutter invoque quand
  l'état est réinséré dans l'arbre. Le clavier se serait ouvert de lui-même.

La règle générale, pour la prochaine fois : **sur un téléviseur, rien qui ouvre une surface plein
écran ne doit le faire au passage du focus.** Seule une activation explicite peut le déclencher.

## Amendement (2026-09-02) — un focus perdu est une app gelée

Sur un téléviseur, tout passe par le focus. S'il n'est nulle part, la télécommande ne fait plus
rien du tout, et l'écran a l'air planté alors qu'il va très bien.

Flutter n'a pas de filet pour ça : quand le widget focalisé disparaît, le focus remonte au
conteneur le plus proche et s'y arrête — état dans lequel les flèches sont sans effet. Or les
listes de cette app se rafraîchissent sous les pieds de l'utilisateur : **revenir d'un film
recharge l'accueil**, ce qui reconstruit « Reprendre la lecture » et détruit la vignette qui avait
le focus.

`TvFocusGuard`, posé à la racine, constate qu'aucun élément actionnable ne détient le focus et le
repose sur le premier atteignable. Le critère est simple : un `FocusScopeNode` qui détient le focus
principal signifie « le focus est entré ici mais ne s'est posé sur rien ».

La règle, à ajouter à celle des surfaces plein écran : **sur un téléviseur, aucune reconstruction
ne doit pouvoir laisser le focus nulle part.** Ce n'est pas au code qui rafraîchit une liste d'y
penser — il ne sait pas ce qui était focalisé — c'est au garde-fou.

## Amendement (2026-09-02) — un focus invisible est un focus absent

Le menu de réglages du chrome Emby s'ouvrait bien à la télécommande, et les flèches y déplaçaient
bel et bien le focus. Rien ne le montrait. Ses lignes étaient des `InkWell`, dont le halo est peint
par le `Material` englobant — donc **sous** le fond opaque du panneau. Anneau, survol, ondulation :
tout atterrissait derrière, et l'utilisateur voyait un menu figé sur lequel OK déclenchait une
ligne qu'il n'avait pas choisie. « Je peux ouvrir Audio mais je ne peux pas me balader dedans. »

La règle de cet ADR ne portait que sur le chrome. Elle vaut partout : **ce que la télécommande
tient doit se voir, sur chaque surface qu'elle peut atteindre** — un menu, un panneau, une liste.
Un focus qu'on ne voit pas ne vaut pas mieux qu'un focus perdu (amendement précédent) : dans les
deux cas l'écran ne dit pas ce que fera la touche suivante.

Trois conséquences dans le menu :

1. Les lignes passent par `TvFocusable` et peignent leur propre remplissage, au-dessus du fond.
2. La télécommande arrive sur **la valeur en cours** — la langue jouée, pas la première ligne — et
   retrouve, en revenant à l'index, la ligne d'où elle était partie.
3. Retour et flèche gauche remontent d'un cran dans le menu au lieu de le fermer entièrement.

Un piège qui vaut pour tout l'app : `onFocusChange` annonce un *changement*. Un nœud déplacé d'une
ligne à l'autre — ce que fait le menu en changeant de section — arrive déjà focalisé, et la
nouvelle ligne n'est jamais prévenue. `TvFocusable` lit donc l'état du nœud à la construction, au
lieu d'attendre qu'on le lui dise.
