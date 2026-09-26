# ADR-0038 — AetherEngine lit tout sur iPhone, Mac et Apple TV

- **Statut :** accepté, en cours. Phases 1 et 2 faites, sous Windows : le plugin
  `packages/onyx_player_apple` existe et l'app s'en sert sur iPhone, Mac et Apple TV. Le Dart est
  analysé et testé ; **le Swift n'a encore été compilé sur aucun Mac**.
- **Date :** 2026-09-26
- **Portée :** le moteur de lecture d'iOS, de macOS et de tvOS. Android (ExoPlayer, ADR-0009),
  Windows et Linux (mpv) ne changent pas.
- **Remplace** l'[ADR-0035](0035-avplayer-en-recopie-sur-iphone-et-mac.md)
  (AVPlayer sur la recopie HLS du serveur), la section 2 de l'[ADR-0028](0028-cible-apple-tv.md)
  (l'Apple TV en HLS seulement), la section 1 de l'[ADR-0011](0011-cible-ios.md) (mpv sur iPhone)
  et le chemin mpv de l'[ADR-0015](0015-mpv-dessine-dans-une-vue-native-sur-macos.md).

## Contexte

Sur les appareils Apple, aucun moteur ne faisait tout :

- mpv lit tout mais chauffe. Sur iPhone, il dessine en OpenGL ES, qu'Apple ne maintient plus, et
  aucune version de mpv ne sait dessiner elle-même sur iOS.
- AVPlayer chauffe peu et seul lui donne le Dolby Vision et l'Atmos sur iOS et tvOS, mais il
  refuse le MKV. Le serveur devait donc recopier le fichier en HLS (ADR-0035), ce qui retardait le
  démarrage, laissait les téléchargements hors ligne sur mpv et privait l'Apple TV de Direct Play.

[AetherEngine](https://github.com/superuser404notfound/AetherEngine) fait cette recopie **sur
l'appareil** : FFmpeg démultiplexe le MKV, le recopie en fMP4 sur un serveur HLS local, et AVPlayer
le lit. Ce qu'AVPlayer ne décode pas (AV1 sans décodeur matériel, VP9, MPEG-2, VC-1) passe par un
décodage FFmpeg ou dav1d vers `AVSampleBufferDisplayLayer`. Il convertit lui-même TrueHD et DTS, le
Dolby Vision profil 7 en 8.1, et décode les sous-titres image.

## Décision

**Sur iPhone, Mac et Apple TV, AetherEngine lit tout, en Direct Play.** Le serveur envoie le
fichier tel quel (`/stream`) et ne fait plus rien de plus pour ces appareils. Le transcodage ne sert
plus qu'à la qualité réduite choisie à la main, qu'AetherEngine lit comme n'importe quel HLS.

- **Un plugin à nous, `onyx_player_apple`**, sur le modèle d'`onyx_player_android` : un contrat
  Pigeon, un lecteur désigné par un identifiant, une vue native qui s'y rattache, un flux d'état
  complet par instantané.
- **Une vue native, jamais une texture** (`UiKitView`, `AppKitView`) : une texture Flutter est en
  8 bits, donc sans HDR. Le cadrage se fait par la taille de la vue, comme dans l'ADR-0035.
- **Les sous-titres arrivent en données**, texte ou bitmap PNG placé en fractions de l'image, et
  sont peints par Flutter : même habillage que sur les autres plateformes.
- **Le journal d'AetherEngine remonte vers Dart**, pour le journal par lecture de l'ADR-0026. Le
  ticket de lecture y est masqué (`EngineLog.registerSecret`).
- **SwiftPM uniquement.** AetherEngine n'existe pas en CocoaPods, et Flutter 3.44 comme flutter-tvos
  résolvent déjà les plugins par SwiftPM.
- **Un seul code Swift pour trois cibles.** flutter-tvos ne lit que `tvos/Package.swift`, et un
  paquet Swift ne peut pas désigner des sources hors de son dossier. `tvos/` porte donc une copie
  de `darwin/`, écrite par `tool/sync_tvos.dart` et gardée identique par
  `app/test/onyx_player_apple_sources_test.dart`. Le même script corrige la garde d'import de
  Pigeon, qui oublie tvOS.
- **AetherEngine est épinglé sur sa mineure** (`7.17.x`), parce qu'il embarque son FFmpeg
  précompilé : une mineure qui flotte changerait le FFmpeg qui tourne.

## Conséquences

- **iOS 18, tvOS 18 et macOS 15 au minimum**, les planchers d'AetherEngine. Les Mac restés sous
  macOS 14 ou avant perdent l'app. C'est accepté.
- **Un moteur tenu par une seule personne**, qui avance vite. Parade : la version épinglée, et un
  plugin à nous entre l'app et le moteur, pour pouvoir le forker sans toucher au reste.
- **La licence** est la LGPL-3.0 avec une exception pour les magasins : une modification du moteur
  lui-même doit être publiée, pas le code de l'app.
- **La cohabitation avec mpv** pendant la transition est prévue par AetherEngine, dont les
  frameworks FFmpeg portent un préfixe `Aether` pour cet usage. À vérifier sur un Mac.

## Dans l'app (phase 2)

- **`AetherPlaybackSession`** remplit `PlaybackSession`, et `createPlaybackSession()` la rend dès
  qu'`AppPlatform.isApple`. Le contrôleur ne connaît plus de moteur Apple à part : `_hlsOnly` ne
  vaut plus que pour le web, et tout le chemin « AVPlayer en recopie » a disparu
  (`_chooseAppleEngine`, `_leaveAvPlayer`, `PlaybackCapabilities.avPlayer` et `appleTv`, le drapeau
  `remux`).
- **Les pistes sont renumérotées pour le contrôleur** (`AetherTracks`) : il retrouve la langue d'un
  sous-titre du fichier par `id - 1` et désigne l'audio par sa position, les conventions de mpv.
  Les sous-titres externes et CEA-608 sont hors numérotation (`isContainerStream`).
- **libmpv n'est plus chargé** sur les appareils Apple : ni `MediaKit.ensureInitialized`, ni
  `MpvNativeView.resolve`, ni le moteur préparé d'avance. Un second FFmpeg dans le processus n'y
  servait plus à rien.
- **Les cibles de déploiement** passent à iOS 18, macOS 15 et tvOS 18, dans les projets Xcode et
  les Podfile.
- **Le réglage « Décodage matériel »** disparaît sur les appareils Apple : AetherEngine choisit
  seul.

## Ce qui reste

1. **Phase 3 :** Mac, puis iPhone, puis Apple TV, avec `docs/validation-lecture.md` sur un vrai
   appareil. Le premier build dira si le Swift compile, et si flutter-tvos accepte une vue native.
2. **Phase 4 :** retirer mpv des builds Apple (`media_kit_libs_ios_video`,
   `media_kit_libs_macos_video`, `onyx_mpv_macos`, `MpvNativeView`,
   `PlaybackCapabilities.mpvGpuNext`), qui y sont encore embarqués sans être chargés.
