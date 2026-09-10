# ADR-0015 — Sur macOS, mpv dessine lui-même dans une vue native

- **Statut :** accepté sur macOS. `OnyxMpv.framework`, universel et embarqué dans l'app, en fait le
  lecteur par défaut sur tous les Mac ; la texture de media_kit ne sert plus que de repli. Le Dolby
  Vision a été vérifié sur un vrai fichier (profil 8, RPU appliqué, sortie PQ).
- **Portée :** la surface vidéo de macOS. Le reste de la chaîne mpv (pistes, sous-titres, reprise,
  réglages) ne change pas, et aucune autre plateforme n'est touchée.
- **Complète** l'ADR-0014, dont elle lève la limite sur le Dolby Vision pour macOS.

## Contexte

Le seul code de mpv qui applique la couche RPU du Dolby Vision passe par libplacebo, dans la sortie
`gpu-next`. media_kit, lui, fait dessiner mpv dans une texture Flutter par l'API de rendu
(`vo=libmpv`), dont le seul moteur est l'ancien renderer — y compris dans mpv 0.41. Tant que l'image
passe par cette texture, le Dolby Vision est ignoré, quelle que soit la façon dont libmpv est
compilé.

Android n'a pas ce problème pour une raison simple : ExoPlayer dessine dans une `SurfaceView`, une
vraie vue du système, et Flutter se compose par-dessus. C'est ce modèle que macOS reprend.

Un obstacle de plus : sur macOS, mpv ne sait pas dessiner dans une vue fournie. Son backend
(`macvk`) crée toujours sa propre fenêtre et ignore `--wid`, ce qui a été vérifié dans les sources
de la 0.41 comme de la branche principale.

## Décision

**mpv dessine avec `gpu-next` dans une vue AppKit posée dans l'arbre Flutter.** Trois morceaux :

1. **Un patch de mpv** (`packages/onyx_mpv_macos/native/patches/`). Quand `--wid` est donné, mpv
   ne crée pas de fenêtre : il insère sa vue dans celle qu'on lui passe, prend sa taille de rendu
   dans cette vue (et la suit quand elle change), ne touche ni à l'activation ni à l'icône de
   l'app, et laisse les clics et le glisser-déposer à l'hôte. Le même patch empêche mpv de
   remplacer la barre de menus de l'app, ce qu'il fait sinon dès qu'il est chargé.
2. **Le plugin `onyx_mpv_macos`**. Il fournit une `AppKitView` dont il donne l'adresse à Dart. Il
   la garde en vie jusqu'à ce que mpv l'ait lâchée : Flutter la libère dès que le widget disparaît,
   alors que mpv peut encore y présenter une image.
3. **Le branchement dans l'app**, activé dès qu'un libmpv patché se charge : `OnyxMpv.framework`,
   embarqué dans l'app (voir « Le binaire livrable »), sinon celui que `build_libmpv.sh` installe
   dans `~/Library/Application Support/Onyx/libmpv/`, ou un autre désigné au lancement
   (`--dart-define=ONYX_LIBMPV=…`). Un binaire absent ou qui ne se charge pas
   fait retomber l'app sur la texture, sans l'empêcher de démarrer (voir `MpvNativeView`). Le
   moteur est créé sans texture (media_kit coupe alors la piste vidéo : il faut la rouvrir) et
   avec `vo=null`. La surface donne `wid` puis `vo=gpu-next` à mpv, et `vo=null` avant de
   disparaître. Le cadrage choisi à l'écran devient des options mpv, et les sous-titres texte
   passent par un overlay Flutter identique à celui de media_kit, qui exige la texture. Le client
   déclare `dv=1` (`PlaybackCapabilities.mpvGpuNext`).

Les options de la sortie vidéo partent d'un isolate à part, jamais du thread de l'interface.
Changer `vo` reconstruit la sortie, et sur macOS cette reconstruction attend le thread principal.
Si l'interface restait bloquée dessus pendant un redimensionnement de fenêtre (qui fait attendre le
thread principal sur celui de l'interface), tout se figerait.

## Vérifié

Un banc d'essai charge le libmpv patché, lui donne une vue dans une fenêtre et lit une vidéo
1080p :

- la sortie est `gpu-next` (MoltenVK sur Apple M1 Pro), avec VideoToolbox sans copie ;
- mpv n'ouvre aucune fenêtre, et sa vue se trouve bien dans celle de l'hôte ;
- la taille de rendu suit la vue : 640×360 donne 1280×720 px, puis 960×540 donne 1920×1080 ;
- l'image remplit la vue sur la capture ;
- après `vo=null`, la vue hôte ne contient plus rien.

L'app compile avec le plugin. **Le Dolby Vision n'a pas encore été vu sur un vrai fichier** :
c'est le test qui reste à faire avant d'accepter cet ADR.

## Le binaire livrable

`native/build_release.sh` construit `OnyxMpv.xcframework` : mpv 0.41.0 patché et toutes ses
dépendances (FFmpeg 8.1, dav1d, freetype, harfbuzz, fribidi, libass, glslang, libplacebo,
MoltenVK), compilées en statique pour arm64 et x86_64 et liées dans un seul binaire de 67 Mo qui ne
dépend que du système (macOS 11 minimum). FFmpeg est construit sans `--enable-gpl` et mpv avec
`-Dgpl=false` : l'ensemble est LGPL. Le podspec du plugin l'embarque dans l'app, qui le cherche
d'abord dans son propre bundle.

Deux choix qui ne se devinent pas :

- MoltenVK est lié en statique à la place d'un chargeur Vulkan : il n'y a pas d'ICD à installer.
  libplacebo doit alors être construit avec `vk-proc-addr`, parce que mpv crée son instance Vulkan
  sans lui fournir `vkGetInstanceProcAddr`.
- libplacebo cherche glslang dans les chemins par défaut du compilateur : le script lui désigne le
  dossier de build et corrige deux appels à `find_library`. Un symbole resté non résolu ne fait pas
  échouer le lien, seulement le chargement chez l'utilisateur : le script le vérifie et fait
  échouer le build.

Vérifié : chargement, intégration dans la vue et rendu sur arm64 et sur x86_64 (Rosetta), et build
release de l'app universel, framework compris.

## Ce qui reste

- **Le patch à maintenir.** Il doit être réappliqué à chaque montée de version de mpv. Il est
  court (4 fichiers) et ne touche que le backend macOS.
- **Les réglages de qualité de media_kit** (`scale=bilinear`, `dither=no`, …) s'appliquent aussi à
  `gpu-next`. Ils ont été choisis pour des téléphones et sont à revoir pour ce chemin.
- **Windows** n'est pas couvert, et le blocage est côté Flutter. mpv sait déjà dessiner dans une
  fenêtre fournie sous Windows (`context_win.c`), et le build shinchiro a libplacebo. Mais Flutter
  3.44 n'a pas de vue native pour Windows (seulement `AndroidView`, `UiKitView`, `AppKitView` et
  le web) : il n'y a nulle part où poser la fenêtre de mpv sous l'interface.
- **iOS** n'est pas couvert, et le blocage est côté mpv. Flutter a `UiKitView`, mais mpv 0.41 n'a
  pas de contexte iOS qui dessine lui-même (Vulkan : Android, macOS, Windows, Linux seulement) :
  il faudrait en écrire un, sur UIKit et MoltenVK, puis construire libmpv pour iOS.
