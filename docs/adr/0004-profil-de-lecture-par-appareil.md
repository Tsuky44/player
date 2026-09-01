# ADR-0004 — Un profil de lecture par classe d'appareil

- **Statut :** accepté
- **Date :** 2026-08-21
- **Portée :** le lecteur natif (libmpv via media_kit) sur Android, téléphone et téléviseur. Le
  web (HTMLVideoElement) et le desktop ne changent pas de comportement.

## Contexte

Toutes les options mpv du lecteur ont été réglées sur des machines de bureau, et les commentaires
qui les accompagnent le disent : 256 Mo de cache demuxer en avant, 64 Mo en arrière, quatre minutes
de readahead, « la copie supplémentaire est négligeable ». Sur 16 Go de RAM c'est vrai, et ça achète
un film qui ne bronche pas quand le Wi-Fi hoquette.

Le même réglage part tel quel sur un Fire TV Stick 4K, qui dispose d'1,5 Go pour Android, son
lanceur et l'app réunis. 320 Mo d'allocation native dans un seul processus, ce n'est plus un tampon,
c'est l'appareil. La pression mémoire qui en résulte est exactement ce que les commentaires du
lecteur décrivent déjà comme « periodic decode stalls » — sauf qu'au lieu d'arriver de temps en
temps sur une machine à 8 Go, elle est l'état permanent.

Le symptôme rapporté suit cette échelle : injouable sur le téléviseur, gênant sur un téléphone,
invisible sur le PC du même réseau.

## Décision

`PlaybackProfile` classe l'appareil et chaque tampon s'exprime en fonction de cette classe. Le
desktop garde exactement ce qu'il avait ; un téléphone récent prend environ un tiers ; un
téléviseur, un appareil déclaré `isLowRamDevice`, ou tout Android sous 3 Go, prennent le profil
contraint (48 Mo en avant, 16 Mo en arrière).

La classe se lit sur l'appareil, pas sur une supposition : `ActivityManager` renvoie la RAM
physique et son propre verdict `isLowRamDevice`. C'est la RAM physique qui compte et non la limite
de tas Java — le cache demuxer de libmpv est une allocation native qui ne touche jamais le tas.

Trois règles de repli, toutes dans le même sens :

- Une requête sans réponse (vieille install de l'app hôte, plateforme sans le canal) vaut
  « contraint ». Se tromper vers un tampon trop petit coûte un peu de rebuffering ; se tromper dans
  l'autre sens coûte le film.
- Le mode TV *détecté* décide, pas le réglage à trois états : un téléphone forcé en mode TV reste un
  téléphone du point de vue de la mémoire.
- La fenêtre de rembobinage ne descend jamais sous 16 Mo, quelle que soit la classe. Le bouton
  « -10 s » est le seek le plus courant du lecteur ; il ne doit pas repartir sur le réseau.

### `vd-lavc-dr` est un contournement de desktop

L'option est forcée à `no` parce que le direct rendering fait geler la vidéo avec l'embarquement par
*render API* de media_kit. Android n'utilise pas cet embarquement : media_kit y passe une Surface
Android à mpv via `--wid` et laisse `vo=gpu` peindre dedans. Le bug visé ne peut pas s'y produire,
tandis que la copie supplémentaire qu'on impose, elle, se paie sur chaque image 4K et sur un GPU de
clé HDMI. Android garde donc le défaut de mpv.

### La détection de pic HDR est un budget, pas un réglage

`hdr-compute-peak` est une passe de calcul sur chaque image. Elle améliore le tone mapping quand le
GPU a de la marge et coûte des images quand il n'en a pas — et un film 4K HDR sur une clé est
précisément le cas où l'image est déjà la chose la plus chère à l'écran. Le profil contraint la
coupe ; les deux autres la laissent.

### Un clip plein écran qui ne clippait rien

La vidéo est enveloppée dans un `AnimatedPhysicalModel` pour la carte de fin de saison, qui la
réduit dans un coin avec un rayon de 16 px. À taille pleine le rayon vaut 0 : le `Clip.antiAlias`
clippait donc un rectangle sur lui-même, sur chaque image décodée. Gratuit sur un GPU de bureau,
pas sur celui d'une clé. Le clip n'est posé que lorsque l'image est réellement réduite.

### Le décodeur zéro copie, nommé explicitement

`hwdec=auto-safe` laisse le choix à la liste blanche de mpv, qui est conservatrice par construction.
Sur Android cela revient à faire recopier vers le CPU une image que le matériel venait de décoder,
sur les appareils les moins capables de se le permettre. `hwdec=mediacodec` garde l'image dans un
tampon que le GPU possède déjà et la donne directement à la sortie vidéo — c'est ce que fait un
lecteur de salon, et c'est la différence entre un film 4K qui passe sur une clé et un qui ne passe
pas.

Ce chemin dépend du MediaCodec du fabricant, et tous ne l'implémentent pas correctement : un mauvais
pilote donne une image verte ou noire avec un son parfait. Cet échec est indétectable depuis l'app —
mpv rapporte les images comme décodées et affichées, elles sont opaques. C'est donc un **réglage**
plutôt qu'une supposition : le défaut prend le chemin rapide, et « Compatible » est à une touche
pour qui possède une des boîtes cassées.

### Le rythme de l'écran, pas seulement celui du décodeur

Un téléviseur est à 60 Hz et un film à 23,976 fps. Soixante ne se divise pas par vingt-quatre : une
image sur deux est tenue une trame de plus que sa voisine — la cadence 3:2. Rien n'est perdu, rien
n'arrive en retard ; l'image avance simplement d'un pas irrégulier, qu'un panoramique lent rend
impossible à ignorer. Aucun travail sur le décodeur, les tampons ou le réseau n'y change quoi que ce
soit, parce que ce n'est pas un manque.

Le lecteur demande donc au panneau un mode dont la fréquence est un multiple entier de celle du
contenu, et le rend en sortant — le catalogue n'est pas à 24 fps, et un panneau laissé au rythme
d'un film ferait saccader chaque défilement de l'app. Même résolution uniquement : choisir le mode
nous regarde, changer ce que l'écran affiche non. Téléviseurs seulement.

### Amendement (2026-08-26) — le repli quand le zéro copie ne prend pas

La section ci-dessus dit que l'échec du chemin zéro copie est indétectable depuis l'app. C'est vrai
d'**un** de ses deux échecs : le mauvais pilote qui décode et dessine de travers, image verte, son
parfait. L'autre est parfaitement visible et n'était pas traité : le décodeur **ne démarre pas du
tout**, mpv l'écrit dans `hwdec-current`, et il se rabat en silence.

Or mpv se rabat de `mediacodec` **directement sur le logiciel** — il n'y a pas d'étape
intermédiaire. Sur une boîte dont le chemin zéro copie ne fonctionne pas, un film 4K est donc décodé
par le CPU. Ce n'est pas une lecture plus lente : c'est deux images par seconde, et la mémoire que
réclame le décodeur logiciel est ce qui fait tuer l'app par le low-memory killer. Le symptôme
rapporté — « le 1080p passe très bien, le 4K charge deux images et ça plante » — est exactement
cette forme.

Le lecteur lit donc `hwdec-current` après la première image, et s'il trouve du logiciel sur un
fichier au-dessus de 1440p, il bascule sur `mediacodec-copy` — qui est du matériel lui aussi, et qui
est le chemin compatible que le réglage proposait déjà à la main. `hwdec` se change à chaud, donc le
film en cours se rattrape sur place.

Borné de tous les côtés : Android seulement, une fois par lecture, uniquement si l'utilisateur n'a
pas épinglé un décodeur lui-même, et uniquement au-dessus de 1440p — en dessous, un décodage
logiciel est du gaspillage sans conséquence, et changer de décodeur sous un film qui passe bien
serait un à-coup pour rien.

L'observation vaut pour **la session**, pas au-delà : les lectures suivantes ouvrent directement sur
le chemin compatible, mais rien n'est écrit dans le réglage. C'est une constatation, pas un choix de
l'utilisateur — l'écrire masquerait un appareil réparé par une mise à jour de firmware, et
écraserait un réglage auquel personne n'a touché.

Quand même le chemin compatible ne suffit pas, le recours n'est plus un décodeur mais une
résolution : le menu Qualité du chrome transcode la source en 1080p, et il est atteignable à la
télécommande.

### Amendement (2026-08-26) — l'adaptation de fréquence devient un réglage

Changer de mode fait renégocier le HDMI : l'image s'éteint une seconde ou deux, et sur certains
ensembles téléviseur/boîtier la surface revient dans un état que la sortie vidéo doit reconstruire —
ce qui se lit comme une lecture qui se fige peu après le démarrage, sur certains films et pas
d'autres. Lesquels n'a rien d'aléatoire : ce sont ceux dont la fréquence a un mode où aller.

Le comportement reste activé par défaut — c'est tout l'intérêt de la fonction — mais il est
désormais désactivable dans les réglages, au même titre que le décodage matériel et pour la même
raison : l'échec dépend du matériel du salon, et il ne doit pas demander une nouvelle version de
l'app.

### Ce qui reste, et qu'on ne peut pas changer ici

Emby lit en Direct Play sans effort sur la même clé, et c'est vrai : son lecteur Android donne les
images de MediaCodec à une `SurfaceView`, que le compositeur matériel affiche sans que l'app ne
touche un pixel. media_kit ne fonctionne pas ainsi — il rend avec OpenGL ES dans un
`TextureRegistry.SurfaceProducer`, et Flutter compose cette texture dans sa propre scène. C'est une
composition plein écran supplémentaire par image, sur le thread raster de Flutter, donc couplée à sa
cadence plutôt qu'au plan vidéo de l'écran.

Les trois décisions ci-dessus retirent tout ce qui peut l'être sans changer cette architecture. Le
reste tiendrait dans un passage de media_kit à une vue de plateforme, ou dans un lecteur ExoPlayer
dédié à Android — les deux sont des chantiers, pas des réglages.

## Conséquences

- Sur un appareil contraint, une coupure réseau de plus de ~45 s de média met le lecteur en pause
  au lieu de puiser dans un tampon de quatre minutes. C'est le compromis assumé : ces appareils
  n'avaient pas les quatre minutes, ils avaient une pression mémoire.
- Le profil est résolu une fois par processus, avant la première frame, comme le mode TV. Il est
  lu à l'ouverture d'un média et la réponse ne change jamais de la vie du processus.
- Une ligne de diagnostic est écrite à la première image : résolution, codec, fps, `hwdec-current`
  (ce que mpv a *réellement* retenu, pas ce qu'on lui a demandé), profil de tampons et fréquence
  d'écran obtenue. Les images perdues sont comptées à la sortie, séparément pour le décodeur et pour
  l'affichage — les deux pannes se ressemblent à l'écran et ne se corrigent pas au même endroit.
- Le levier suivant n'est pas dans ces options : sur un appareil contraint, lire en Direct Play une
  source 4K à haut débit reste un pari sur le décodeur *et* sur le Wi-Fi de l'appareil. Le serveur
  sait déjà transcoder en HLS — c'est ce que fait le web, qui n'a pas le choix. Étendre ce repli aux
  appareils contraints est une décision de produit (il coûte du CPU serveur) et fera l'objet de son
  propre ADR.
