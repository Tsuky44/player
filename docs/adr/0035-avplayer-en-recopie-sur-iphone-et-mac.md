# ADR-0035 — AVPlayer en recopie sur iPhone et Mac, mpv pour le reste

- **Remplacé** par l'[ADR-0038](0038-aetherengine-sur-les-appareils-apple.md) le 2026-09-26 :
  AetherEngine lit tout en Direct Play sur iPhone et Mac. `ApplePlaybackSession`,
  `AvPlayerPlaybackSession` et `AvPlayerRemux` n'existent plus.
- **Statut :** accepté, écrit sous Windows. Le Dart et le Go sont testés ; rien n'a encore tourné sur
  un iPhone ni sur un Mac.
- **Date :** 2026-09-24
- **Portée :** le choix du moteur sur iOS et macOS (`ApplePlaybackSession`, `AvPlayerRemux`), la
  surface d'AVPlayer (`AvPlayerPlaybackSession`), les capacités déclarées (`PlaybackCapabilities`)
  et le plafond de recopie du serveur (`Capabilities.Remux`).
- **Prolonge :** [ADR-0028](0028-cible-apple-tv.md) (AVPlayer en HLS sur l'Apple TV) et
  [ADR-0014](0014-capacites-de-lecture-declarees-par-le-client.md).

## Contexte

mpv fait chauffer les iPhone et les Mac. Sur iOS, media_kit le fait dessiner en OpenGL ES, une API
qu'Apple ne maintient plus et qui passe par une couche de traduction vers Metal. Chaque image est
rendue une fois par mpv, puis recomposée par Flutter. AVPlayer, lui, pose l'image que le décodeur
matériel a produite directement dans la couche d'affichage. C'est le chemin qu'Apple optimise pour
la batterie.

AVPlayer n'ouvre pas le MKV. Le serveur sait déjà le lui rendre lisible sans ré-encoder : il
recopie les pistes dans des segments HLS fMP4, comme pour l'Apple TV. Mais au-delà de 12 Mb/s
(`COPY_BITRATE_CEILING_MBPS`), il ré-encodait l'image en H.264, alors qu'un remux 4K dépasse ce
plafond. Passer tout un iPhone sur AVPlayer aurait donc occupé un cœur du serveur par film, pour une
image moins bonne.

## Décision

**Sur iPhone et Mac, AVPlayer lit ce que le serveur peut recopier, et mpv lit le reste en Direct
Play.** Le serveur ne ré-encode jamais pour économiser la batterie du client.

- **Le choix se fait à l'ouverture**, sur la liste de pistes (`MediaTracksCache`, que la page du
  film a déjà remplie ; 1,5 s au plus, sinon mpv). `AvPlayerRemux.refusal` écarte ce qu'AVPlayer ne
  peut pas prendre en recopie : une vidéo autre que H.264 ou HEVC (VP9, AV1, MPEG-2, VC-1…), plus
  de 10 bits, le Dolby Vision, et des sous-titres image choisis d'emblée. L'audio ne compte pas :
  le serveur convertit le TrueHD et le DTS en E-AC-3, pour quelques pourcents d'un cœur.
- **`ApplePlaybackSession`** porte les deux moteurs derrière l'interface `PlaybackSession`. Une
  session HLS s'ouvre dans AVPlayer quand le contrôleur l'a décidé (`streamsOnAvPlayer`), un fichier
  dans mpv. Le moteur qui ne joue pas est arrêté, et la surface suit celui qui joue.
- **AVPlayer demande la résolution de la source et `remux=1`.** Le serveur recopie alors au-delà de
  son plafond de débit : ce lecteur aurait tiré ce débit de toute façon en Direct Play. L'Apple TV
  l'envoie aussi, pour la même raison.
- **La vue native (`AVPlayerLayer`)**, par `video_player_avfoundation` 2.9 ou plus, et non la
  texture. Elle garde le HDR, que l'écran tone-mappe lui-même s'il ne l'affiche pas, et n'a pas de
  copie par image. Le cadrage se fait par la taille de la vue, sans transformation.
- **Retour à mpv, à la seconde près**, quand AVPlayer refuse la session avant la première image,
  quand le serveur refuse de l'ouvrir (plafond de sessions, disque), quand l'utilisateur choisit
  des sous-titres image (les incruster ré-encoderait le film), ou quand il choisit « Direct » dans
  le menu de qualité.

## Conséquences

- La charge du serveur par film lu sur AVPlayer est celle d'une recopie : quelques pourcents d'un
  cœur, plus la conversion audio pour TrueHD et DTS. Le disque reste borné par le frein à 32 s
  d'avance et la purge de l'ADR-0033.
- **Le Dolby Vision reste sur mpv**, profils 8 compris. Le serveur étiquette le HEVC recopié en
  `hvc1`, et un profil 5 lu ainsi sort vert. Pour les passer à AVPlayer, il faudrait que le serveur
  étiquette `dvh1` et annonce le profil dans la playlist.
- **L'AV1 reste sur mpv**, même sur les puces qui le décodent en matériel (A17 Pro, M3) : l'app ne
  sait pas encore le demander au système.
- Un démarrage sur AVPlayer attend la première seconde de session du serveur, là où mpv ouvrait le
  fichier directement. Un saut hors de la fenêtre produite rouvre une session, comme sur l'Apple TV.
- Les sous-titres texte passent par le WebVTT que la session écrit (ADR-0031), peint par Flutter.
- **À vérifier sur un appareil** : la vue native sous les contrôles (flous compris) sur iOS et
  macOS, le HDR sur un écran XDR, le retour à mpv après une panne d'AVPlayer, et l'écran qui reste
  allumé (`wakelock_plus`).
