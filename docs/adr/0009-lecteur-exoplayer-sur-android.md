# ADR-0009 — ExoPlayer sur Android, mpv ailleurs

- **Statut :** accepté, en cours de réalisation
- **Date :** 2026-08-27
- **Portée :** la chaîne de lecture sur Android (téléphone et téléviseur). macOS, Windows et le web
  ne changent pas de moteur.

## Contexte

Un fichier 4K est inregardable sur téléviseur : deux images par seconde, ou l'app tuée. Le 1080p
passe très bien. Emby, sur le même appareil, lit le même fichier sans effort.

L'ADR-0004 avait identifié la cause et l'avait laissée ouverte : media_kit rend avec OpenGL ES dans
un `SurfaceProducer`, que Flutter recompose ensuite dans sa scène. Trois faits mesurés depuis :

1. mpv rend chaque image avec un shader (`vo=gpu`) — première passe GPU plein écran.
2. Flutter recompose cette texture sur son thread raster — deuxième passe.
3. `AndroidVideoController` dimensionne la surface de rendu sur **la résolution native du
   fichier** : un 4K est rendu en 3840×2160 même sur un panneau 1080p.

Emby ne fait rien de tout cela. ExoPlayer donne les images de MediaCodec à une `SurfaceView`, que
le plan vidéo du contrôleur d'affichage compose : l'image ne traverse ni le GPU ni la scène.

## Décision

### 1. ExoPlayer remplace mpv sur Android, entièrement

Pas de cohabitation. Deux moteurs sur une même plateforme, c'est un mécanisme de bascule, un APK
qui garde ses ~48 Mo de `libmpv.so` (quatre ABI dans un APK universel), et un support où « ça ne
marche pas » devient « sur lequel des deux ? ».

**Le repli pour un fichier qu'ExoPlayer refuse est le transcodage**, pas un second décodeur. Il
existe déjà, il est testé, il produit du H.264/AAC que tout Android décode, et il est déjà exposé
dans le menu Qualité.

L'étanchéité passe par un **import conditionnel**, comme `server_discovery` et `tv_link_host` :
sur Android les symboles mpv n'existent pas dans le code compilé. `MediaKit.ensureInitialized()`
n'est pas appelé là-bas, et l'umbrella `media_kit_libs_video` cède la place aux paquets par
plateforme, sans Android.

### 2. Une `SurfaceView`, avec ce que ça interdit

C'est tout l'intérêt, et le prix est structurel : **une `SurfaceView` est une couche du système,
pas un pixel Flutter.** Flutter ne peut ni la mettre à l'échelle, ni la clipper en arrondi, ni lui
donner une ombre.

La carte de fin, qui réduit la vidéo à 34 % avec coins arrondis et ombre portée, ne peut donc pas
survivre telle quelle sur Android — téléviseur **et téléphone**. Elle sera redessinée en
superposition sur une vidéo pleine taille. Le pinch-to-zoom passera par le redimensionnement natif
de la vue. Dessiner *par-dessus* — chrome, sous-titres, menus — fonctionne normalement.

Sacrifier le plan vidéo pour préserver une animation, ce serait renoncer au 4K pour un coin
arrondi.

La composition doit être **hybride, et explicitement**. Le widget `AndroidView` de Flutter appelle
`PlatformViewsService.initAndroidView`, qui compose en *Texture Layer* : la vue Android est rendue
dans une texture Flutter. Une `SurfaceView` dessine sur sa propre couche système et n'est pas
capturable par ce chemin — au mieux un rectangle noir, au pire une mesure de la composition GPU
qu'on cherche à supprimer. `initExpensiveAndroidView` force la composition hybride ; son nom vise
les appareils sous Android 9, alors qu'ici c'est le seul mode qui donne le plan vidéo.

### 3. Un contrôleur partagé, un port fin

`PlayerController` fait 2052 lignes, dont **118 touchent mpv** — concentrées dans sept méthodes
nommées. Le reste (sessions HLS, reprise, heartbeat, modèle de pistes, préférences, bascule de
qualité) est de la logique d'app, et reste partagé.

Seules ces 118 lignes ont deux implémentations, derrière un port `PlaybackSession`. Les widgets
d'UI — sept d'entre eux reçoivent aujourd'hui un `mk.Player` — passeront au port. Le comportement
de macOS et Windows est gelé ; leur code, non : dupliquer sept widgets pour ne pas les toucher
produirait deux chromes qui divergeraient au premier correctif.

### 4. Le contrat est généré, pas écrit

Pigeon génère les deux côtés à partir de `pigeons/messages.dart`, dans un paquet dédié
(`packages/onyx_player_android/`).

La raison n'est pas l'élégance mais la boucle de retour : chaque itération coûte un APK, un
transfert, une installation et un film lancé sur un téléviseur qu'aucun outil de développement
n'atteint commodément. Une clé de map mal orthographiée dans un canal écrit à la main ne casse pas
à la compilation — elle casse là-bas, en silence. Pigeon la fait casser ici.

Le paquet donne aussi un source set JUnit, où vivra le seul morceau de ce chantier vérifiable sans
appareil : le processeur audio du point 5.

### 5. L'audio reproduit le comportement actuel, le passthrough vient après

L'ADR-0005 pose trois coefficients de repli stéréo (`center_mix_level=1.0`,
`surround_mix_level=0.7`, `lfe_mix_level=0.3`) appliqués par le rééchantillonneur de mpv. ExoPlayer
n'a pas d'équivalent : ce sera un `AudioProcessor` maison portant les mêmes nombres.

Le passthrough (AC3/DTS/Atmos envoyés bruts au téléviseur) est **reporté**, bien qu'il soit le plus
gros gain audio du portage. C'est un gain que mpv ne donne pas non plus aujourd'hui : ne pas le
livrer d'emblée ne perd rien, alors que rater le mixage perdrait quelque chose. La migration ne doit
changer aucun comportement — c'est ce qui rend la recette possible : « le son est-il identique ? ».

### 6. Les sous-titres réutilisent ce qui existe

Le texte vient déjà de fichiers `.vtt` externes servis par le backend, qui rebase lui-même les cues
pour l'offset HLS. ExoPlayer chargera la même URL et remontera ses cues à la `SubtitleView` Flutter
partagée : rendu identique partout, un seul style, et la logique de positionnement au-dessus de la
timeline reste du code commun.

Les pistes bitmap (PGS/VOBSUB) passent par le burn-in du transcodage, qui existe déjà. Conséquence
assumée : sur Android, choisir un sous-titre bitmap coûtera une session HLS, là où c'était gratuit
en Direct Play.

### 7. Les réglages n'affichent jamais une option inopérante

`PlaybackProfile` (`constrained` / `mobile` / `desktop`) reste un **vocabulaire partagé** : la
classe d'appareil est vraie indépendamment du moteur. Chaque backend le traduit dans ses unités —
octets et secondes pour mpv, millisecondes de `DefaultLoadControl` pour ExoPlayer.

L'écran Réglages, lui, n'affiche que ce que le backend courant expose. « Décodage matériel » passe
de trois à deux options sur Android : « Rapide » et « Compatible » désignent la même chose quand
MediaCodec est le seul chemin, et un bouton qui ne fait rien n'est pas une interface préservée.

### 8. Les codecs audio sont interrogés, pas devinés

mpv décode DTS-HD et TrueHD en logiciel ; ExoPlayer dépend du MediaCodec de la puce. Le plugin
interroge le `MediaCodecList` une fois et remonte les MIME décodables ; le contrôleur partagé
tranche Direct Play ou transcodage **avant** d'ouvrir, à partir du codec que le sondage serveur lui
a déjà donné. Pas de faux départ visible.

L'extension FFmpeg de Media3 (compilée au NDK, audio seulement) est **reportée jusqu'à ce que les
chiffres la réclament** : un téléviseur récent décode probablement AC3, E-AC3 et DTS, et on ne paiera
pas une étape de build pour un problème qu'on n'a peut-être pas.

## Ce qui décide de la suite

Le premier jalon est une tranche verticale : le paquet, le contrat, la `SurfaceView`, et un lecteur
qui sait ouvrir, lire, pauser, chercher. Ni pistes, ni sous-titres, ni HLS, ni reprise, ni chrome.

**Son verdict est un chiffre**, pas une impression : le même fichier 4K, soixante secondes, les
images perdues d'ExoPlayer contre le `frame-drop-count` de mpv. **Moins de 50 % d'images perdues en
moins est un échec.** On essaie alors une `TextureView` — une demi-journée, qui distingue « c'est la
double passe » de « c'est le plan vidéo » — et si l'aiguille ne bouge toujours pas, **on arrête** et
le 4K sur téléviseur redevient une affaire de transcodage.

Ce seuil est écrit ici parce qu'il doit être décidé avant d'avoir dépensé, pas après.

## Conséquences

- L'APK Android perd les ~48 Mo de libmpv.
- Le téléphone passe sur ExoPlayer aussi, et perd temporairement l'animation de carte de fin et son
  pinch-to-zoom, pour un gain nul de son côté. C'est le prix de n'avoir qu'un moteur par plateforme,
  et ces deux fonctions lui seront rendues.
- Trois moteurs vivent dans le dépôt — mpv, ExoPlayer, hls.js — mais un seul par plateforme.
- Le web ne bouge pas.
