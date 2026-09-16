# ADR-0021 — Les keyframes se lisent dans l'index du conteneur, pas en démultiplexant

- **Statut :** accepté. Le chemin natif est en place, mesuré contre ffprobe sur MP4, MOV, MKV et
  un fichier tout-intra, avec repli automatique.
- **Date :** 2026-09-16
- **Portée :** l'estimation d'intervalle entre keyframes du serveur (`server/streaming/analysis.go`,
  `server/streaming/keyframes*.go`). Le probe de pistes (`ProbeTracks`) reste sur ffprobe, ainsi que
  tout l'encodage.

## Contexte

`AnalyzeStreamingFile` est appelée à chaque probe, deux fois : à l'indexation
(`ProbeAndPersist`) et après un probe à chaud (`PersistProbeAfterLiveProbe`). Elle lançait un
`ffprobe -read_intervals 0%+60 -show_packets` pour trouver les keyframes des soixante premières
secondes.

Lire des flags de paquets oblige ffprobe à faire passer soixante secondes de vidéo dans son
démultiplexeur. Pour un 1080p à 10 Mbit/s cela fait ~75 Mo lus par fichier, pour un 4K plusieurs
centaines. Sur une médiathèque posée sur un partage réseau, c'est le scan entier qui devient de
l'attente disque.

Le cas qui gêne vraiment est ailleurs. `PersistProbeAfterLiveProbe` est lancée en goroutine depuis
`GetMediaTracks` — elle ne bloque pas la requête, mais elle démultiplexe ces soixante secondes
**pendant que l'utilisateur commence à lire ce même fichier**. Le serveur tirait donc des centaines
de mégaoctets du même disque, en concurrence avec la lecture, au moment précis où celle-ci démarre.
C'est une cause de mise en mémoire tampon qui n'apparaît dans aucun journal.

Or l'information est déjà écrite dans le fichier : tout conteneur qui permet de chercher une
position stocke où sont ses keyframes. MP4 et QuickTime tiennent une table de sync samples (`stss`,
avec `stts` pour la durée des échantillons), Matroska tient des cues. Quelques dizaines de kilo-octets
à un emplacement connu.

## Décision

### 1. L'index du conteneur est lu directement, ffprobe devient le repli

`keyframeTimesFromIndex` lit `stss`/`stts`/`mdhd` en MP4 et les cues en Matroska. Ce qu'elle ne sait
pas lire — TS, AVI, WMV, un fichier qu'elle juge malformé — repart vers `probeMaxGOPSeconds`, qui
est l'ancien chemin inchangé. Le repli n'est jamais une erreur : il est plus lent, pas plus faux.

Mesures sur des fichiers produits par FFmpeg, 70 s, GOP connu :

| Fichier | Index natif | ffprobe | Écart sur la valeur |
|---|---|---|---|
| gop2s.mp4 | 291 µs | 31 ms | 0,000 |
| gop2s.mkv | 343 µs | 31 ms | 0,000 |
| gop2s.mov | 329 µs | 31 ms | 0,000 |
| faststart.mp4 | 251 µs | 37 ms | 0,000 |
| allintra.mkv | 781 µs | 54 ms | 0,000 |
| gop2s.avi, gop2s.ts | repli | — | — |

### 2. Le format vient des octets, pas de l'extension

Un `.mkv` qui est en réalité un MP4 est courant. Le lire comme un Matroska donnerait une valeur
faussement assurée au lieu d'un repli, donc le choix se fait sur `1A45DFA3` en tête de fichier ou
`ftyp` en position 4.

### 3. En Matroska, le `SeekHead` évite de traverser les clusters

Les cues sont écrites après les clusters. Les atteindre en avançant d'élément en élément coûte deux
lectures par cluster : sans conséquence sur un fichier normal qui en compte quelques dizaines, mais
un fichier tout-intra en a un par image — 1750 sur 70 s, soit 22 ms passés à sauter, plus cher que
le démultiplexage qu'on voulait éviter. Le `SeekHead` donne la position des éléments de premier
niveau, ce pour quoi il existe. Il fait tomber ce cas à 781 µs.

Un `SeekHead` périmé — un fichier retouché par un outil qui ne l'a pas réécrit — pointe n'importe
où. Chaque position est donc revalidée contre l'élément qui s'y trouve, et le parcours linéaire
reprend la main si elle ne correspond pas.

### 4. La fenêtre de soixante secondes est conservée

Elle n'a plus de raison d'être côté natif : tout l'index est en main, mesurer le fichier entier
serait gratuit et plus juste. Elle est gardée parce que les deux chemins doivent répondre la même
chose — deux implémentations d'une même mesure qui divergent sont pires qu'une mesure étroite. La
fenêtre s'élargira des deux côtés à la fois, ou pas du tout.

### 5. L'absence de `stss` n'est pas une absence de donnée

Un MP4 sans table de sync samples dit que **tous** les échantillons sont des keyframes, ce que
produit un codec tout-intra comme ProRes ou MJPEG. Le lire comme « aucune keyframe » donnerait un
intervalle de zéro.

## À vérifier

- Sur la médiathèque réelle, que la part de fichiers partant en repli reste marginale (elle devrait
  se limiter aux TS et aux vieux AVI).
- Que la disparition du démultiplexage de fond supprime bien la mise en mémoire tampon observée au
  démarrage de lecture sur partage réseau.

## Conséquences

- Un scan ne lit plus les fichiers eux-mêmes pour cette mesure, seulement leurs en-têtes.
- La spec Matroska n'impose pas une cue par keyframe. mkvmerge et FFmpeg en écrivent une par
  keyframe vidéo, mais un multiplexeur qui les écrirait clairsemées ferait paraître l'intervalle
  plus long qu'il n'est. Le risque est accepté : `gop_seconds` est écrite en base et journalisée,
  et aucune décision de lecture ne s'en sert aujourd'hui.
- Les temps sont des temps de décodage. Avec des images B, la présentation diffère des offsets de
  composition (`ctts`), mais ce décalage est quasi constant sur un flux : l'écart entre deux
  keyframes, seule chose mesurée ici, ne bouge pas. `ctts` n'est donc pas lue.
- Le chemin ouvre la suite : `ProbeTracks` lit aujourd'hui les mêmes en-têtes par un `ffprobe`
  séparé, et pourrait s'appuyer sur le même code pour supprimer le dernier lancement de processus
  du scan.
