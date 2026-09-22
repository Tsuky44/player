# ADR-0028 — Une cible Apple TV, par flutter-tvos et AVPlayer

- **Statut :** accepté, réalisé — première compilation sur un Mac et premier essai sur une Apple TV
  encore à faire (voir Conséquences)
- **Date :** 2026-09-22
- **Portée :** l'app cliente sur Apple TV (nouveau dossier `app/tvos/`), quelques branches du code
  Dart partagé, le workflow de publication, et deux corrections serveur qui profitent à tous les
  lecteurs d'Apple.
- **Prolonge :** [ADR-0003](0003-android-tv-et-appairage-par-qr-code.md) (le mode télécommande),
  [ADR-0011](0011-cible-ios.md) (la cible iOS)

## Contexte

L'app existe sur Android TV. On voulait la même chose sur Apple TV : même interface, même
télécommande, même connexion par QR code.

Le `.ipa` iOS ne s'installe pas sur une Apple TV, et aucun réglage n'y change rien. Le binaire est
marqué pour la plateforme iOS dans son en-tête Mach-O, et tvOS refuse de le lancer. L'Apple TV
demande un binaire compilé avec le SDK `appletvos`. Or Flutter ne propose pas cette cible.

Le code Dart, lui, était presque prêt. `TvMode`, le focus, la touche OK et le lecteur à la
télécommande ne dépendent pas d'Android. Seule la détection du mode TV en dépendait. La touche
Retour aussi, puisqu'Android la transforme lui-même en `popRoute` (corrigé : `TvBackAction`).

## Décision

### 1. flutter-tvos, épinglé sur la ligne 3.44

[flutter-tvos](https://github.com/fluttertv/flutter-tvos) est une CLI qui accompagne le SDK
Flutter, sur le modèle de flutter-tizen et flutter-elinux. Elle apporte un moteur précompilé pour
tvOS et son propre Flutter, qu'elle ne modifie pas. Le tag `v3.44.9-tvos.1.5.1` suit la même
version mineure que le reste de la CI (3.44). Le Dart qui compile ici compile donc là-bas.

`app/tvos/` est le projet Xcode que `flutter-tvos create` génère, rendu depuis le modèle de ce tag.
Il est indépendant de `app/ios/` : autre SDK, autre Podfile, autre `AppDelegate`. L'identifiant
d'app (`com.projectplayer.onyx`) et l'équipe de signature sont ceux du projet iOS.

### 2. AVPlayer, en HLS seulement

libmpv n'existe pas pour tvOS dans la forme que media_kit embarque. Le recompiler aurait fait un
second chantier, sur un moteur qu'Apple ne met pas en avant sur son propre appareil.
Le lecteur est donc AVPlayer, par `video_player_tvos`. Le code passe par
`video_player_platform_interface` et non par le paquet `video_player`, qui ajouterait son propre
ExoPlayer au build Android (`AvPlayerPlaybackSession`).

AVPlayer refuse le MKV. L'Apple TV suit donc le chemin du navigateur : pas de Direct Play, une
session HLS dès que la liste des pistes est connue (`_hlsOnly` dans le contrôleur). Ce n'est pas
un transcodage : l'Apple TV déclare `PlaybackCapabilities.appleTv` (fMP4, H.264, HEVC 10 bits,
AAC, (E-)AC-3, ALAC, FLAC, 8 canaux), et le serveur **recopie** ce qui tient dans un segment.
Seuls TrueHD et DTS sont convertis, comme pour tout client fMP4. Elle demande toujours la
résolution de la source, puisqu'une recopie ne coûte rien au serveur.

Le port ne fournit ni flux de position ni sous-titres externes. La session relit la position
toutes les 250 ms, découpe le WebVTT du serveur (`VttCues`) et le peint avec le
`SubtitleOverlay` d'Android.

### 3. Deux corrections serveur, pour tous les lecteurs d'Apple

- **`-tag:v hvc1`** sur le HEVC recopié en fMP4. FFmpeg écrit `hev1` pour une copie sortie d'un
  MKV, et AVPlayer refuse le HEVC étiqueté `hev1`. Safari et iOS avaient le même problème sans
  qu'on le voie, puisque mpv lisait le fichier directement.
- **`#EXT-X-START:TIME-OFFSET=0`** dans les playlists média. Une session est une playlist EVENT
  qui commence au point demandé. Sans cette balise, AVPlayer la traite comme du direct et démarre
  trois segments avant le dernier produit. Or une recopie va plus vite que le temps réel : ce
  serait plusieurs minutes plus loin que prévu. Les autres lecteurs supposaient déjà zéro.

Le serveur distingue aussi l'`.ipa` Apple TV (`Onyx-x.y.z-tvos.ipa`) de celui de l'iPhone. Sinon
ils se disputaient la même case « ios » de `/api/downloads`.

### 4. Les plugins : les portages utiles, rien pour le reste

flutter-tvos n'embarque que les plugins qui déclarent la plateforme `tvos`.

| Plugin | Sur Apple TV |
|---|---|
| shared_preferences, flutter_secure_storage, path_provider, sqflite, connectivity_plus | portage `*_tvos` de fluttertv.dev |
| media_kit | remplacé par AVPlayer (`video_player_tvos`) |
| package_info_plus | le portage exige une interface 4.x incompatible avec la 9 épinglée ; l'hôte donne la version par `onyx/device` |
| wakelock | inutile : l'hôte suspend l'économiseur d'écran pendant la lecture (`setKeepScreenOn`) |
| screen_brightness, mobile_scanner, file_picker, window_manager | sans objet sur un téléviseur, jamais appelés |

`AppPlatform.isIOS` exclut désormais l'Apple TV, qui a son propre `isTvOS`. Le moteur tvOS répond
pourtant `true` à `Platform.isIOS`. Mais tout ce que ce drapeau garde est propre au téléphone
(luminosité, barre d'état, gestes, chrome réduit, caméra) et se coupe donc de lui-même.

### 5. Ce qui ne s'offre pas sur Apple TV

- **Le mode télécommande est forcé**, et son réglage masqué : l'interface du téléphone y serait
  inutilisable.
- **Pas de téléchargements.** tvOS ne laisse à une app que des dossiers de cache, que le système
  vide quand la place manque.
- **Pas de page « Applications »** : une Apple TV n'ouvre pas de lien et ne choisit pas de fichier.

## Conséquences

- **Pas de HDR ni de Dolby Vision pour l'instant.** `video_player_tvos` peint dans une texture
  Flutter en BGRA 8 bits, le seul chemin vérifié sur une vraie Apple TV. L'Apple TV déclare donc
  `hdr: false`, et le serveur tone-mappe les sources HDR : l'image est juste mais ré-encodée. La
  vue native du port (`AVPlayerLayer`, `VideoViewType.platformView`) lèverait cette limite ; elle
  reste à essayer sur un appareil.
- **Pas d'adaptation de la fréquence d'écran** (`AVDisplayCriteria`), contrairement à Android. À
  ajouter à l'hôte tvOS le jour où le 24p saccade.
- **L'installation demande une signature.** Sideloadly et AltStore ne gèrent pas l'Apple TV.
  L'IPA de la CI n'est pas signé. Pour installer, on passe par `scripts/build-tvos-ipa.sh --install`
  depuis un Mac appairé à l'Apple TV (identifiant Apple gratuit : expiration à 7 jours), ou par
  TestFlight avec un compte payant.
- **Le job CI `build-tvos` est en `continue-on-error`.** Il repose sur un outillage
  communautaire : s'il échoue, la Release part sans l'IPA Apple TV plutôt que pas du tout.
- **Rien n'a encore été compilé.** Ce changement a été écrit sous Windows. Le Dart est analysé et
  testé ; le Swift, le projet Xcode et le job CI ne le sont qu'au premier run sur macOS.
