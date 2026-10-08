# ADR-0056 — Qualité automatique : descendre avant la coupure, remonter sur mesure

- **Statut :** accepté. Mesuré sous Windows (mpv) contre un serveur à la ligne bridée — voir
  « Ce qui a été essayé ». **Rien n'a tourné sur Android, sur un appareil Apple ni dans un
  navigateur.**
- **Date :** 2026-10-08
- **Portée :** `app/lib/screens/player/playback/auto_quality.dart`,
  `app/lib/screens/player/hooks/use_auto_quality.dart`,
  `app/lib/screens/player/hooks/player_controller_auto.dart`,
  `app/lib/services/hls_preload_io.dart`,
  `app/lib/services/api/playback.dart` (`awaitHlsReady`, `measureLineBps`),
  `server/streaming/manager.go` (`Claim`, `DropStandby`), `server/streaming/plan.go`,
  `server/devline/`, `server/handlers/playback.go` (`source_bitrate_bps`),
  `app/tool/auto_probe_main.dart` (le banc d'essai).
- **Remplace :** [ADR-0053](0053-le-lecteur-descend-seul-quand-la-connexion-ne-suit-pas.md).
- **Prolonge :** [ADR-0022](0022-echelle-de-transcodage-avec-debits.md) (l'échelle de débits),
  [ADR-0033](0033-sessions-hls-bornees.md) (une session par ticket).

## Contexte

L'ADR-0053 faisait descendre le lecteur d'un barreau après trois coupures en trois minutes. Le
spectateur voyait donc trois fois l'image se figer avant que quoi que ce soit change, puis un
sablier pendant le changement, et la lecture ne remontait jamais.

Un service comme Crunchyroll ne se fige pas : chaque épisode y est encodé d'avance à tous les
débits, découpés aux mêmes instants, et le lecteur passe de l'un à l'autre à la jointure de deux
morceaux, sur ce qu'il mesure de sa ligne. Onyx encode à la demande, un seul débit à la fois, et
ouvrir une session prend plusieurs secondes. La jointure gratuite n'existe pas ici. Le reste se
reprend : décider sur une mesure, avant la coupure, et préparer la suite pendant que l'image
continue.

## Décision

### 1. « Auto » est une entrée du menu Qualité, et le réglage d'origine

En Auto, une lecture démarre en Direct Play et y reste tant que la ligne suit. Choisir « Direct »
ou un débit dans le menu retire la main à l'Auto jusqu'à la fin de la lecture, ou jusqu'à ce
qu'on la choisisse à nouveau. Le réglage Réglages → Lecture → Connexion dit seulement comment une
lecture *démarre* sur cet appareil ; il reprend le choix de qui avait éteint l'adaptation de
l'ADR-0053.

### 2. Descendre sur la pente du tampon, d'un seul saut

Chaque seconde, `AutoQuality` reçoit l'avance en mémoire. Sa pente dit ce que la ligne porte, en
secondes de film reçues par seconde : une avance qui perd une demi-seconde par seconde est une
ligne qui livre la moitié de ce qui est lu.

- Sous 92 % reçus **et** moins de quinze secondes d'avance, la ligne est accusée — avant la
  coupure.
- Le barreau visé est le premier à 80 % ou moins de ce que la ligne porte. Fichier à 10 Mbit/s,
  ligne à 5 : 720p · 3,5 Mbit/s directement, sans passer par les barreaux intermédiaires.
- La ligne se juge sur vingt secondes, mais le barreau se choisit sur les huit dernières : la
  fenêtre entière mêle l'avant et l'après, et une ligne tombée à la moitié s'y lisait à 89 %.
- Une coupure qui survient quand même fait descendre tout de suite. Il n'y a plus de compte
  jusqu'à trois.
- Ne comptent pas : les quinze secondes qui suivent le démarrage, une recherche, une reprise, un
  changement de piste ou de source ; la fin du média, quand tout ce qui reste est déjà en
  mémoire ; un fichier téléchargé.

Un barreau se juge sur ce qu'il envoie **réellement** (`AutoLadder`). Le serveur annonce le débit
du fichier dans la réponse des pistes (`source_bitrate_bps`), et une session dit si elle recopie
l'image : le barreau natif de la source, recopié, pèse ce que pèse le fichier.

### 3. Un barreau tient son débit

Mesuré dès le premier essai : sur un fichier H.264 à 10 Mbit/s, « 1080p · 4 Mbit/s » recopiait
le fichier et en envoyait 10. Descendre ne soulageait pas la ligne. `PlanVideo` refuse maintenant
de recopier un fichier plus lourd que le barreau demandé. Le barreau d'origine de la résolution
du fichier (« 1080p » pour un 1080p) fait exception : c'est celui que le web et les replis
demandent *pour* obtenir la recopie, jusqu'au plafond de `COPY_BITRATE_CEILING_MBPS`.

### 4. Remonter sur une mesure de la ligne, jamais sur une supposition

La pente ne dit rien d'une ligne qui suit : le serveur ne produit une session qu'à la vitesse de
la lecture. Après quatre-vingt-dix secondes de calme, le lecteur **mesure** : il tire un morceau
du fichier pendant trois secondes au plus (`measureLineBps`), et y ajoute ce que la lecture
consommait au même moment — la mesure ne voit que ce qu'elle laisse.

- Un barreau n'est pris que si la ligne vaut une fois et demie son débit, et le Direct Play une
  fois et demie celui du fichier.
- La remontée va au plus haut que la mesure justifie, pas d'un cran : avec seize barreaux, un
  cran par mesure mettrait vingt minutes à revenir d'une baisse passagère.
- Une mesure qui ne justifie rien, ou une descente dans les trois minutes qui suivent une
  remontée, double l'attente avant la suivante, jusqu'à dix minutes.
- Avoir la fin du film en mémoire n'empêche pas de remonter : un barreau à 1 Mbit/s tient un
  film entier en mémoire en trois minutes.
- Quand l'appareil ne lit pas le fichier lui-même (navigateur, codec ou piste audio qu'il ne
  décode pas), le sommet est le barreau que le lecteur avait pris à la place.

### 5. Le changement de source se prépare pendant que l'image continue

Changer de barreau, c'est changer de session, donc de source pour le moteur, qui repart sans
rien en mémoire. Sur une ligne lente — la raison même du changement — c'est l'image figée le
temps d'en recevoir assez. Trois choses l'évitent :

1. **La session commence en avant de la lecture.** Le lecteur la demande pour une seconde
   future, de quatre à vingt secondes plus loin selon ce que l'avance en mémoire tiendra (une
   ligne qui livre la moitié fait durer onze secondes d'avance une vingtaine).
2. **Son début est téléchargé d'avance** (`HlsPreload`) : six secondes d'image et de son, pendant
   que l'ancienne source joue ce qu'elle a déjà. Le moteur l'ouvre par une adresse de la boucle
   locale où ces segments l'attendent ; le reste de la session passe par le même relais, qui le
   demande au serveur tel quel.
3. **Le moteur change de source à la seconde où elle commence.** Ni sablier, ni position qui
   saute.

Avec moins de six secondes d'avance, il n'y a rien à préserver : la session s'ouvre tout de
suite, sablier compris. Si la lecture se fige avant la seconde visée, pareil — sans jamais sauter
de contenu. Si quelqu'un reprend la main entre-temps (recherche, pause, autre choix), la
préparation est abandonnée et la lecture reste où elle est.

Le relais n'existe que sous Windows et Linux, où mpv lit et où il a été essayé. Ailleurs le
moteur ouvre la session préparée directement, et part dès qu'il a de quoi afficher
(`applyStreamingTuning(sourceReady:)`).

### 6. Une session préparée ne remplace rien avant d'être lue

L'ADR-0033 fait qu'une nouvelle session condamne les autres du même ticket, trente secondes plus
tard. Une préparation abandonnée aurait donc tué la session que le lecteur gardait. `standby=1`
sur `/start` ouvre une session **en attente** :

- elle ne remplace les autres qu'à son premier segment vidéo servi (`Claim`), et un segment pris
  d'avance (`warm=1`) ne compte pas ;
- une nouvelle attente détruit la précédente du même ticket (`DropStandby`) ;
- une attente que personne n'est venu lire est détruite au bout de quarante-cinq secondes, et le
  ramasse-miettes passe toutes les quinze secondes au lieu de trente ;
- le lecteur la détruit lui-même dès qu'il renonce, et en se fermant.

La réponse confirme `standby: true`. Un serveur plus ancien ne le dit pas : le lecteur sait alors
que la session en cours est déjà condamnée, et va au bout du changement au lieu de renoncer.

### 7. Une ligne lente à volonté, pour le développement

`ONYX_DEV_LINE_KBPS` bride tous les flux vidéo du serveur à un débit commun (`server/devline`),
et `PUT /api/dev/line?kbps=N` le change pendant une lecture. Sans la variable, rien n'est
enveloppé et la route n'existe pas. `app/tool/auto_probe_main.dart` lit un film avec le vrai
moteur, change le débit selon un plan et note ce que fait le lecteur : chaque gel de plus de
0,4 s, chaque écart de plus de 0,25 s entre le film et l'horloge.

## Ce qui a été essayé

Windows, mpv, un film de dix minutes en H.264 1080p à 10 Mbit/s, un serveur dans Docker. La ligne
passe de 14 à 5 Mbit/s, puis à 1,5, puis redevient libre.

| | ADR-0053, par construction | Premier jet de cet ADR, mesuré | À la fin, mesuré |
|---|---|---|---|
| Ligne de 14 à 5 Mbit/s | trois coupures, puis sablier | gel de 5,4 s, deux descentes | 720p d'un saut, aucun gel |
| Ligne de 5 à 1,5 Mbit/s | trois coupures de plus | — | 360p, aucun gel |
| Ligne rétablie | ne remonte pas | — | Direct Play, aucun gel |

« Aucun gel » : rien au-dessus du seuil du banc, 0,4 s d'image arrêtée et 0,25 s d'écart entre le
film et l'horloge, sur les deux derniers parcours complets. La colonne de l'ADR-0053 est ce que sa
règle implique ; elle n'a pas été rejouée.

Les essais ont trouvé, et fait corriger, ce qu'aucun test n'aurait vu :

- le tampon du démarrage était pris pour une coupure, et la lecture descendait à la première
  seconde ;
- un barreau recopiait un fichier plus lourd que lui (§3) ;
- mpv ouvrait une session déjà avancée par la fin, quarante-quatre secondes plus loin : FFmpeg
  prend une playlist sans fin pour du direct et ignore `EXT-X-START` (`live_start_index=0`) ;
- la mesure de la ligne ne comptait pas ce que la lecture prenait déjà : 1,7 Mbit/s « libres »
  sur une ligne à 5 ;
- avec la fin du film en mémoire, l'Auto ne remontait plus ;
- le moteur redemandait au serveur un segment que le relais était en train de recevoir : 3,4 s
  de gel pour deux téléchargements du même fichier ;
- **une session ouverte hors d'un point-clé rejouait jusqu'à un GOP de son et affichait une
  position trop avancée d'autant**, pour toute session et depuis toujours : la piste audio
  recopiée partait du point-clé précédent, et le multiplexeur décalait toute la session
  (`-copypriorss:a 0`, quand l'image est encodée) ;
- `PlaybackSession.bufferedAhead` rendait une position sous mpv et une avance ailleurs : la barre
  de tampon et les recherches dans une session HLS additionnaient l'une à l'autre sur ExoPlayer
  et AetherEngine.

**Ce que ces essais ne couvrent pas** : ExoPlayer et AetherEngine (sans relais, donc avec un
gel attendu d'une à trois secondes à la descente, non mesuré) ; un navigateur ; une vraie ligne,
dont les à-coups ne sont pas ceux d'un débit bridé ; une source 4K ou HEVC, dont l'encodage
démarre plus lentement ; un film à points-clés espacés de dix secondes.

## Alternatives écartées

- **Un flux à débits multiples** (plusieurs variantes dans la playlist, le moteur choisit). C'est
  le modèle de Crunchyroll, et il suppose tous les barreaux encodés en même temps. mpv, de plus,
  ne change pas de variante en cours de lecture.
- **Changer d'encodeur dans la même playlist** (`EXT-X-DISCONTINUITY`). Le serveur devrait écrire
  lui-même la playlist à la place de FFmpeg, et le premier passage, du fichier vers une session,
  resterait un changement de source.
- **Un second moteur préchargé sous le premier**, échangé à l'instant voulu. Deux décodeurs à la
  fois, ce que bien des boîtiers de télévision n'ont pas en 4K. Le relais donne le même résultat
  avec un seul.
- **Suspendre le téléchargement de l'ancienne source** pour laisser la ligne au début de la
  nouvelle. Essayé : la ligne ne se libère qu'une fois les tampons du système pleins, et
  l'ancienne source a d'autant moins à jouer. Allonger la préparation fait mieux.
- **Lire le débit dans le moteur** (`cache-speed` de mpv, `BandwidthMeter` d'ExoPlayer). Chaque
  moteur le donne à sa façon, quand il le donne, et aucun ne mesure la réserve d'une ligne
  qu'une session bridée par le serveur n'utilise pas.
- **Une bibliothèque d'adaptation de débit.** Celles qui existent pilotent des variantes
  préencodées.

## Conséquences

- **Une lecture en Auto peut ouvrir un transcodage sans qu'on l'ait demandé**, et le quitter de
  même. Le plafond de sessions de l'ADR-0033 borne la charge ; une attente y compte comme une
  session, sauf pour son propre ticket.
- **Un barreau au-dessous du débit du fichier est maintenant encodé**, là où il était recopié
  quand la résolution le permettait : c'est un encodage de plus pour qui choisissait un tel
  barreau dans le menu, et c'est ce que son libellé promettait.
- **Chaque mesure coûte jusqu'à trois secondes de ligne**, toutes les quatre-vingt-dix secondes
  au plus, puis de plus en plus rarement. Elle ne part que si la lecture a huit secondes d'avance.
- **Sous Windows et Linux, une session ouverte par l'Auto est lue à travers l'app** (le relais),
  jusqu'au prochain changement de source.
- **Dans un navigateur**, la mesure n'aboutit que si le morceau arrive entier dans le délai :
  la réponse n'y est pas lue au fil de l'eau. L'Auto y descend comme ailleurs et remonte moins
  volontiers.
- La mesure de la pente se trompe d'une quinzaine de points sur huit secondes : une descente
  tombe parfois un barreau trop bas, et la mesure suivante la corrige.
- L'annonce « Connexion lente : qualité réduite à… » disparaît. Le menu Qualité dit ce que l'Auto
  joue (« Auto · 720p »).
- Un serveur d'avant l'ADR-0022 ne publie pas de débits : l'entrée Auto n'apparaît pas.
