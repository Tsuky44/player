# ADR-0014 — Le client déclare ce qu'il sait lire, le serveur fait le moins de dégâts

- **Statut :** accepté, réalisé côté serveur, Android et web — le passthrough de bureau reste à faire
- **Portée :** `server/streaming` en entier, la sortie audio d'ExoPlayer, et le paramétrage des
  sessions HLS côté client. Le Direct Play ne change pas : il n'est déjà rien d'autre que le fichier.
- **Complète** l'ADR-0005, dont elle restaure la propriété perdue par le portage ExoPlayer
  (voir « Le repli qui ne s'arrêtait plus » ci-dessous).

## Contexte

Le transcodeur décidait pour un client imaginaire : un navigateur qui lit du H.264 8 bits 4:2:0 et
de l'AAC stéréo, et rien d'autre. Ce client existe — c'est Firefox — mais c'est le **plus faible de
tous ceux que ce projet sert**, et tous les autres recevaient ce qui avait été écrit pour lui.

Concrètement, sur un fichier 4K HEVC 10 bits HDR10 avec une piste E-AC-3 5.1 — c'est-à-dire le
fichier le plus banal d'une bibliothèque moderne :

| | ce qui partait | ce qui aurait pu partir |
|---|---|---|
| image | ré-encodée en H.264 8 bits, un cœur entier | recopiée, quelques pourcents d'un cœur |
| HDR | écrasé sans conversion de courbe | transmis tel quel |
| audio | AAC stéréo 160 kb/s | E-AC-3 5.1 recopié |

Les trois lignes ont la même cause : personne ne demandait jamais à l'appareil ce qu'il savait
faire. Et les trois échouent de la même façon quand on se trompe — pas par un message d'erreur mais
par une image noire sur un son qui joue, ou par une image grise et délavée, ce qui est le symptôme
le plus difficile à rattacher à sa cause.

### Ce que le conteneur interdisait

Une partie du problème n'était pas le décodeur mais le MPEG-TS. Il n'a pas de type de flux pour le
VP9, l'AV1, le FLAC ni l'Opus : `-c copy` de l'un d'eux fait refuser l'en-tête à FFmpeg, qui sort
avant son premier segment — donc `/start` expire et le média ne se charge pas du tout. Le code
listait ces codecs comme « non copiables » sans dire que la raison était le muxer, ce qui rendait la
restriction permanente alors qu'elle tenait à une ligne de commande.

### Le repli qui ne s'arrêtait plus

L'ADR-0005 promet que les niveaux de repli sont « inertes quand il le faut » : sur une machine
reliée à un ampli, mpv envoie ses six canaux et ne les consulte jamais. C'est vrai de mpv, parce
que c'est swresample qui décide de rematrixer ou non.

Ce n'était pas vrai du portage ExoPlayer. `DialogueForwardDownmix.onConfigure` retournait deux
canaux **dès que l'entrée en avait plus de deux**, sans jamais consulter ce que la sortie savait
porter. Un boîtier relié en HDMI à un ampli qui reçoit du PCM 5.1 se retrouvait donc en stéréo,
alors que six canaux passaient. Le commentaire de la classe affirmait le contraire, ce qui est la
seule raison pour laquelle personne ne l'a vu.

## Décision

**Le client déclare ses capacités à chaque `/start`, et le serveur choisit le chemin le moins
destructif compatible avec ce qu'il a entendu.**

```
POST /api/v1/stream/{id}/start
  ?container=fmp4&vcodec=h264,hevc,av1&acodec=aac,ac3,eac3
  &channels=6&bitdepth=10&hdr=1&dv=0
```

Chaque paramètre est facultatif **et retombe indépendamment** sur sa valeur d'origine, si bien
qu'un client peut élargir exactement l'axe dont il est sûr. Ne rien envoyer donne le comportement
d'avant, à l'octet près : c'est ce qui fait que les versions déjà installées continuent de
fonctionner sans rien savoir de tout ceci.

### Ce que chaque client déclare, et pourquoi

- **ExoPlayer (Android, Android TV)** : rien n'est supposé, tout est mesuré. Les décodeurs viennent
  de `MediaCodecList`, le nombre de canaux et le **passthrough** des `AudioCapabilities` — donc de
  l'ampli branché, ce qui fait changer la réponse avec le câble — et les formats HDR de l'écran
  lui-même. Le passthrough compte séparément du décodage : un boîtier peut faire traverser du Dolby
  Digital Plus jusqu'à l'ampli sans avoir de décodeur pour lui, et **c'est le seul chemin par lequel
  du Dolby Atmos arrive intact**, le lit d'objets voyageant en JOC dans le flux E-AC-3.
- **mpv (bureau, iOS)** : une constante, parce que mpv porte ses propres décodeurs et que la liste
  ne dépend ni du système ni du matériel. `channels=8` est déclaré même si mpv sort souvent en
  stéréo : quand la sortie l'est, c'est mpv qui replie avec les niveaux de l'ADR-0005, donc le même
  résultat qu'un repli serveur sans le ré-encodage. `hdr=1` pour la même raison — mpv sait toujours
  quoi faire d'une source HDR, la transmettre ou la tone-mapper sur le GPU, et les deux valent mieux
  qu'un ré-encodage. `dv=0` en revanche : le rendu par l'API `libmpv` ne traite pas la couche RPU.
- **Navigateur** : ce que `MediaSource.isTypeSupported` répond, profil par profil. `channels=2` et
  `bitdepth=8` restent imposés quoi qu'il réponde — un onglet n'a pas de sortie multicanal
  exploitable, et sa surface de composition reste en 8 bits.

### Les segments passent en fMP4 quand le client le demande

C'est ce qui lève l'interdiction du conteneur : HEVC, AV1, VP9, FLAC et Opus y ont une place, et
c'est le seul format de segment qui transporte les métadonnées HDR d'une copie. Le MPEG-TS reste le
défaut, donc le chemin qui tourne en production ne bouge que pour les clients qui ont demandé autre
chose.

### Le HDR n'est jamais envoyé à qui ne peut pas l'afficher

Trois cas, et un seul comportement par cas :

1. le client affiche le HDR → l'image est recopiée, métadonnées comprises ;
2. il ne l'affiche pas → l'image est ré-encodée **avec tone mapping** (`zscale` en lumière
   linéaire, `tonemap=hable`, retour en BT.709, et les balises colorimétriques qui vont avec) ;
3. le Dolby Vision profil 5 sans décodeur Dolby Vision → cas 2, parce que sa couche de base est dans
   un espace colorimétrique privé et sort verte partout ailleurs. Les profils 7, 8.1 et 8.4 ont une
   couche de base HDR10 ou HLG et relèvent du cas 1.

Ce que ce projet **ne** fait pas : encoder en HDR. Tout ré-encodage sort en H.264 SDR 8 bits. Le
HDR ne survit que sur le chemin de la copie, ce qui est un choix assumé — x265 10 bits sur le Xeon
sans GPU de production ne tient pas le temps réel, et un encodeur sous le temps réel ne rattrape
jamais un tampon qu'il a laissé se vider.

### Le repli stéréo redevient conditionnel

`DialogueForwardDownmix` reçoit maintenant ce que la sortie peut porter et **se retire de la chaîne**
dès qu'elle porte plus de deux canaux. Les trois nombres de l'ADR-0005 ne changent pas ; ce qui
change est qu'ils ne s'appliquent plus qu'au cas qu'ils décrivent, c'est-à-dire à un repli
inévitable.

## Conséquences

- Sur un téléviseur relié à un ampli, un fichier HEVC + E-AC-3 5.1 arrive **tel quel**. Le serveur
  déplace des octets au lieu d'occuper un cœur, et le surround — Atmos compris quand le passthrough
  est disponible — n'est plus détruit en chemin.
- La bande passante monte sur ces sessions : copier veut dire envoyer le débit du fichier. Le
  plafond existant (`ONYX_COPY_BITRATE_CEILING`, 12 Mb/s par défaut) reste le garde-fou, et
  `BANDWIDTH` annonce le débit réel plutôt que celui du préréglage.
- `CHANNELS` dans le master dit enfin la vérité par rendition. C'était `"2"` en dur, ce qui devenait
  faux dès qu'une piste surround survivait — et ce n'est pas cosmétique : un lecteur choisit une
  rendition en partie là-dessus.
- Le probe stocké gagne un numéro de version. Les entrées écrites par une version antérieure sont
  re-sondées une fois, parce qu'un champ absent ne se distingue pas d'un champ qui répond « non » —
  et qu'une entrée périmée enverrait éternellement un HDR sur le chemin SDR.
- **Le tone mapping demande un FFmpeg construit avec libzimg.** Sans `zscale`, le serveur n'en fait
  pas plutôt que de mourir sur un filtre inconnu, et le dit une fois dans le journal. C'est à
  vérifier sur l'image de production : un FFmpeg sans zimg rend les sources HDR délavées pour tout
  client SDR.
- Le passthrough de bureau (`--audio-spdif`) n'est pas fait. C'est le seul moyen d'obtenir de
  l'Atmos sur un Mac ou un PC relié à un ampli, et ça ne peut pas être activé par défaut : sur un
  périphérique qui déclare mal ses formats, ça donne du silence. Ça demande un réglage explicite.
- **Le Direct Play n'est pas « tout ce que le moteur ouvre ».** Le FFmpeg que media_kit publie
  (mac, Windows, iOS) est compilé `--disable-all` avec une liste blanche de décodeurs sans `truehd` ;
  ExoPlayer n'a rien pour le TrueHD, le DTS ou l'(E-)AC-3 sans MediaCodec ni passthrough. Dans les
  deux cas la piste était listée et muette. Corrigé à la source : les paquets `media_kit_libs_*`
  sont surchargés (`packages/`, `dependency_overrides`) pour pointer vers des builds libmpv à FFmpeg
  complet, et ExoPlayer reçoit le décodeur FFmpeg de NextLib derrière MediaCodec — le passthrough
  reste prioritaire. Toutes les pistes se lisent en Direct Play, sans être modifiées.
  `PlaybackCapabilities.missingDirectPlayAudio` reste comme filet (l'AC-4 sur Android) : une piste
  qui en fait partie fait passer en HLS à la résolution de la source.

## Note pour la suite

La question « ce client peut-il lire ceci » est maintenant posée à un seul endroit
(`streaming.PlanVideo` / `streaming.PlanAudio`) et à partir d'une seule structure
(`streaming.Capabilities`). Toute nouvelle contrainte — un codec de plus, un profil de moins, une
limite de débit par appareil — s'y ajoute et se propage partout, y compris dans le master playlist
qui interroge exactement les mêmes fonctions pour se décrire. Ne pas rouvrir de chemin de décision
parallèle : c'est précisément ce qui avait laissé `CHANNELS="2"` mentir pendant que le transcodeur
faisait autre chose.
