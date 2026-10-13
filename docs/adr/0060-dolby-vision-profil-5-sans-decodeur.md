# ADR-0060 — Dolby Vision profil 5 sans décodeur : HLS, et la RPU appliquée par libplacebo

- **Statut :** accepté, réalisé. Les tests Go et Dart passent et la chaîne FFmpeg a été exécutée
  dans l'image Alpine sur une source HDR10. **Aucun vrai fichier profil 5 n'a encore été vu avec
  les bonnes couleurs** : FFmpeg ne sait pas en fabriquer un, il faut un fichier de la médiathèque.
- **Date :** 2026-10-13
- **Portée :** `server/streaming/tonemap_dovi.go`, `server/streaming/ffmpeg.go`,
  `server/streaming/previews.go`, `server/streaming/probe.go`, `server/Dockerfile`,
  `app/lib/services/playback_capabilities.dart`, `app/lib/models/media_tracks.dart`,
  `app/lib/screens/player/hooks/player_controller_tracks.dart`.
- **Complète** [ADR-0014](0014-capacites-de-lecture-declarees-par-le-client.md), dont le cas 3
  (« profil 5 sans décodeur → tone mapping ») était décidé mais ne donnait pas une image juste.
- **Lève** la dernière conséquence de l'[ADR-0016](0016-apercus-de-la-barre-de-lecture.md) (aperçus
  aux couleurs fausses).

## Contexte

Un épisode 4K HEVC « Dolby Vision » sans repli HDR10 — un profil 5 — sortait avec des visages roses
et verts sous Windows. Deux trous, l'un derrière l'autre :

1. **Le Direct Play ne passe par aucun plan.** `PlanVideo` refuse bien de recopier un profil 5 à un
   client sans décodeur Dolby Vision, mais l'app native ouvre d'abord le fichier elle-même, et rien
   ne lui disait que cette image-là lui est illisible. mpv dans la texture Flutter (Windows, Linux)
   n'applique pas la couche RPU (ADR-0014, ADR-0015) : le fichier se décode sans erreur, en rose et
   vert.
2. **Le repli serveur avait les mêmes couleurs.** La chaîne `zscale` + `tonemap` prend la couche de
   base pour du YCbCr BT.2020. Celle d'un profil 5 est en IPTPQc2, et seule la RPU dit comment en
   revenir. L'ADR-0016 le notait déjà pour les aperçus.

## Décision

### 1. Le serveur dit au client que l'image demande un décodeur Dolby Vision

`VideoStreamInfo` publie `needs_dolby_vision`, dérivé de la même fonction que `PlanVideo`
(`needsDolbyVisionDecoder`) : la règle « c'est le profil 5 » reste écrite une seule fois, côté
serveur.

### 2. Le client quitte le Direct Play quand son moteur local n'applique pas la RPU

`PlaybackCapabilities.dolbyVisionInDirectPlay` dit ce que le moteur fait d'un fichier qu'il lit
lui-même. Il vaut `dolbyVision` partout sauf sur les appareils Apple, où AetherEngine lit le Dolby
Vision d'un fichier mais pas celui d'un segment recopié (ADR-0038).

À l'arrivée de la liste des pistes, un profil 5 que le moteur ne sait pas montrer part en HLS,
**au plus en 1080p**, et l'Auto ne revient pas au Direct Play. La résolution d'origine ne sauverait
rien : l'image est ré-encodée de toute façon.

Un fichier téléchargé reste lu tel quel : hors ligne, il n'y a pas de serveur pour le convertir.

### 3. Le serveur applique la RPU avec libplacebo

Pour un profil 5, `toneMapperFor` remplace la chaîne `zscale` par le filtre `libplacebo`, le seul
de FFmpeg qui applique la RPU. La mise à l'échelle reste devant : `scale` ne retire les métadonnées
Dolby Vision d'une image que si les primaires ou le transfert changent, pas la taille (vérifié dans
`vf_scale.c`, FFmpeg 8).

libplacebo demande un périphérique Vulkan, ouvert explicitement (`-init_hw_device vulkan`) : laissé
à lui-même, le filtre refuse un Vulkan logiciel. L'image du serveur embarque donc
`mesa-vulkan-swrast` (lavapipe).

Les réglages du filtre coupent ce qu'un rendu logiciel ne tient pas. Mesuré sur 16 threads, 4K HEVC
10 bits vers 1080p x264 `veryfast` :

| Chaîne                                              | Images/s |
| --------------------------------------------------- | -------- |
| libplacebo, défauts, mise à l'échelle par le filtre | 6        |
| `scale` puis libplacebo, défauts                    | 12       |
| + sans détection de crête, gamut `clip`, sans tramage | 21     |
| + `disable_linear`, `skip_aa`                       | 30       |

Les mêmes sources en profil 7 ou 8 gardent la chaîne `zscale` : leur couche de base est du HDR10.

### 4. Sans Vulkan, l'ancienne chaîne

`libplaceboUsable` filtre réellement une image, une fois par processus : le filtre figure dans la
liste de FFmpeg même quand aucun pilote Vulkan n'est installé. S'il échoue, le profil 5 retombe sur
`zscale` — couleurs fausses, mais une lecture — et le journal dit une fois quoi installer.

## Conséquences

- L'image du serveur grossit d'environ 240 Mo (LLVM, dont lavapipe dépend). La mémoire au repos ne
  bouge pas : la bibliothèque n'est chargée que par le FFmpeg d'une session profil 5.
- Sur un serveur sans GPU, ce tone mapping tient le temps réel en 1080p de justesse, et moins bien
  sur une source à images clés rapprochées (16 images/s mesurées avec une image clé par seconde).
  La qualité automatique descend alors d'un barreau. Un hôte avec un GPU Vulkan exposé au conteneur
  n'a pas cette limite.
- Un serveur installé hors Docker doit avoir un pilote Vulkan ; sinon il garde les couleurs fausses
  et le dit dans son journal.
- Un profil 5 perd son HDR sur Windows et Linux : il arrive en H.264 SDR. Le garder demanderait
  `gpu-next` dans une vue native, ce que l'ADR-0019 a écarté pour Windows.
- Les aperçus d'un profil 5 sont refaits dans un autre dossier ; les anciens partent à l'éviction.
- Un serveur d'avant cette ADR ne publie pas `needs_dolby_vision` : le client y garde le Direct
  Play, donc le défaut d'origine.
