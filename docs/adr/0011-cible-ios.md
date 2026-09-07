# ADR-0011 — Une cible iOS, sur mpv et distribuée hors magasin

- **Statut :** accepté, réalisé — première compilation sur appareil encore à faire (voir
  Conséquences)
- **Date :** 2026-09-04
- **Portée :** l'app cliente sur iPhone et iPad. Aucune autre plateforme ne change, aucun code Dart
  partagé n'est touché.

## Contexte

L'app existe pour macOS, Windows, Android et le web. Il manquait l'iPhone — l'appareil qu'on a dans
la poche dans le train, c'est-à-dire exactement la situation pour laquelle les téléchargements hors
ligne de l'ADR-0010 ont été écrits.

Un client iOS ne demandait pas de nouveau code applicatif : `AppPlatform.isIOS` existait déjà,
`isMobile` couvrait déjà iOS, et le bouton de téléchargement d'installeur renvoie déjà `null` pour
cette plateforme. Ce qui manquait était entièrement dans le dossier `ios/` — et dans la façon de
sortir un `.ipa` qu'on puisse installer.

## Décision

### 1. mpv, comme sur macOS et Windows

L'ADR-0009 a remplacé mpv par ExoPlayer **sur Android**, pour une raison qui ne se transpose pas :
le chemin de rendu Android faisait traverser au 4K deux passes GPU et une surface dimensionnée sur
la résolution du fichier. iOS n'a ni ce chemin ni ce problème, et `AVPlayer` n'est pas ExoPlayer —
il refuse MKV, et une grande partie d'une bibliothèque privée est en MKV.

Donc `createPlaybackSession()` rend une `MpvPlaybackSession` sur iOS, par simple absence de cas
particulier. `media_kit_libs_ios_video` embarque libmpv et ses dépendances (~100 Mo de
`xcframework`), téléchargées par CocoaPods à l'installation des pods. Le paquet
`onyx_player_android` ne déclare que la plateforme Android : rien de lui n'entre dans le binaire
iOS.

### 1 bis. Deux réglages du lecteur ne se transposent pas tels quels

Le travail fait sur le lecteur Android vaut sur iPhone sans rien changer — le cadrage et le
pincement passent par `Video(fit:)` de media_kit, donc par Flutter, là où Android devait descendre
au natif — à deux exceptions près, toutes deux au contact du matériel.

**La courbe de luminosité ne s'applique qu'à Android.** La luminosité de fenêtre d'Android est
linéaire en rétroéclairage : la moitié de la barre donnait un écran déjà perçu comme au maximum, et
`PerceivedBrightness` remet la courbe que l'œil attend. `UIScreen.brightness` d'iOS, lui, *est* la
position du curseur système, courbe comprise. L'appliquer aussi là-bas la poserait deux fois et
tasserait toute la plage utile dans le bas de la barre.

**Le chrome est dessiné 10 % plus petit sur iPhone.** À largeur égale il y lisait plus gros que sur
Android. Seul ce qui est *dessiné* rétrécit — textes, icônes, marges : les cibles tactiles gardent
leur taille, parce qu'un chrome 10 % plus petit et 10 % plus dur à toucher n'est pas le même
échange (`EmbyChromeMetrics.scaledBy`).

### 2. Le HTTP en clair est autorisé, explicitement

Le serveur est chez soi, sur `http://192.168.x.x:8080`, sans certificat. App Transport Security
bloque ça par défaut. `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` lèvent l'interdiction —
c'est le pendant exact du `android:usesCleartextTraffic="true"` du manifeste Android, et c'est la
même décision : un client de serveur auto-hébergé ne peut pas exiger TLS de l'utilisateur.

`NSLocalNetworkUsageDescription` s'y ajoute pour une raison distincte : depuis iOS 14, balayer son
propre /24 (`ServerDiscovery`) déclenche une demande de permission « réseau local », et une app qui
ne fournit pas ce texte se voit refuser l'accès **sans dialogue** — la découverte échouerait en
silence.

### 3. La session audio est configurée dans `AppDelegate`

media_kit ne touche pas à `AVAudioSession`. Sans intervention, l'app reste en `soloAmbient` : le
bouton silencieux de l'iPhone coupe le son du film, et la lecture s'arrête à l'écran verrouillé.
Ça ne ressemble pas à un défaut de configuration, ça ressemble à un lecteur cassé.

`AppDelegate` pose donc `.playback` / `.moviePlayback` au démarrage, et l'Info.plist déclare
`UIBackgroundModes: audio`. Trois lignes de Swift, dans le seul endroit qui s'exécute avant que
quoi que ce soit ne joue.

### 4. Un `.ipa` non signé, resigné à l'installation

Pas d'App Store. La bibliothèque est privée, il n'y a pas de public, et la revue d'Apple
demanderait des réponses (contenu de la bibliothèque, HTTP en clair) qui n'ont pas de sens ici.

`scripts/build-ios-ipa.sh` produit par défaut un `.ipa` **non signé** : un zip contenant
`Payload/Runner.app`, que Sideloadly ou AltStore resigne avec l'identifiant Apple de la personne au
moment de l'installation. Aucun compte développeur payant, et une app qui expire au bout de 7 jours
— c'est le compromis normal du sideloading, et il est acceptable parce qu'installer est une action
d'une minute qu'on refait rarement.

`--signed` reste là pour le jour où un compte développeur existe : Xcode signe, et le `.ipa`
s'installe par Apple Configurator, TestFlight ou un MDM.

## Conséquences

- Trois moteurs dans le dépôt (mpv, ExoPlayer, hls.js), toujours un seul par plateforme — iOS
  rejoint la colonne mpv.
- Le `.ipa` pèse ce que pèse libmpv, comme le faisait l'APK avant l'ADR-0009. C'est le prix de lire
  du MKV sans transcoder.
- **Les fichiers hors ligne sont sauvegardés dans iCloud.** `getApplicationSupportDirectory()`
  pointe vers `Library/Application Support`, que iOS inclut dans les sauvegardes. Un film
  téléchargé gonfle donc la sauvegarde de l'appareil. Le remède est un attribut
  (`NSURLIsExcludedFromBackupKey`) posé sur `onyx_offline` par du code natif — pas fait, à faire
  avant que quiconque télécharge sérieusement sur iPhone.
- L'app n'apparaît pas dans son propre écran de téléchargements : `_currentPlatformKey()` rend
  `null` sur iOS, faute d'installeur publiable par le serveur. C'est le comportement voulu — un
  `.ipa` ne s'installe pas depuis un navigateur.
- La compilation exige un Mac avec la **plateforme iOS installée dans Xcode** (Xcode ▸ Settings ▸
  Components, ~8,4 Go). Le SDK livré avec Xcode ne suffit pas : sans ce composant, `xcodebuild` ne
  trouve aucune destination et le build échoue avant de compiler la moindre ligne. C'est ce qui
  bloque la première compilation sur appareil de cette cible, et non le code.
