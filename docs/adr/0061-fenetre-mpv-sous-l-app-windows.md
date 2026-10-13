# ADR-0061 — Sur Windows, mpv dessine dans sa propre fenêtre, glissée sous celle de l'app

- **Statut :** accepté, actif par défaut sous Windows **pour les seuls Dolby Vision profil 5**.
  Toutes les autres lectures gardent la texture de media_kit, inchangée. Les couleurs et le suivi
  de fenêtre ont été vus dans l'app sur un vrai profil 5 quand l'option couvrait toutes les
  lectures ; la bascule par média, elle, n'a tourné que sur le banc.
- **Date :** 2026-10-13
- **Portée :** la surface vidéo de Windows — `app/lib/utils/win32_video_window_io.dart`,
  `app/lib/screens/player/playback/mpv_window_host*.dart`,
  `app/lib/screens/player/playback/mpv_native_surface.dart`, `app/lib/utils/mpv_native_view_io.dart`,
  `app/windows/runner/video_backdrop.h`, `app/windows/runner/flutter_window.cpp`.
- **Prolonge** l'[ADR-0015](0015-mpv-dessine-dans-une-vue-native-sur-macos.md), qui notait Windows
  comme non couvert, et l'[ADR-0060](0060-dolby-vision-profil-5-sans-decodeur.md).
- **Ne contredit pas** l'[ADR-0019](0019-decodage-sans-copie-sous-windows.md) : le libmpv livré
  reste le même, sans recompilation.

## Contexte

Un Dolby Vision profil 5 ne s'affiche juste qu'avec `gpu-next`, que la texture de media_kit ne
sait pas piloter (ADR-0014). L'ADR-0060 l'envoie donc au serveur, qui le ré-encode en 1080p SDR.
Sur un petit serveur, ce transcodage ne tient pas le temps réel : le média ne se regarde plus du
tout. Il faut que le Direct Play marche.

L'ADR-0015 s'arrêtait sur un blocage côté Flutter : pas de vue native sous Windows, donc nulle part
où poser la fenêtre de mpv *dans* l'interface.

## Décision

**La fenêtre de mpv n'est pas dans l'interface : elle est dessous.**

1. Le moteur est celui de toutes les lectures : media_kit, sa texture, `vo=libmpv`. À l'arrivée
   des pistes, si le serveur annonce un profil 5 (`needs_dolby_vision`, ADR-0060), le contrôleur
   appelle `PlaybackSession.useDolbyVisionOutput` et la session mpv remplace sa surface : la
   texture laisse la place à `MpvWindowHost`. Vérifié sur le banc — un lecteur media_kit passé de
   `vo=libmpv` à `vo=gpu-next` en cours de lecture continue sans coupure.
2. `MpvWindowHost` pose les options de fenêtre (sans bordure, sans focus, sans clavier ni souris)
   puis `vo=gpu-next`. mpv ouvre sa propre fenêtre de premier niveau, avec son fil et sa boucle de
   messages.
3. **Le runner recolle cette fenêtre sous celle de l'app à chaque `WM_WINDOWPOSCHANGED`**
   (`video_backdrop.h`) : déplacement, redimensionnement, réduction, changement de rang. Dart lui
   dit laquelle et où par des propriétés de fenêtre (`SetProp`) — la fenêtre de mpv, et les marges
   de la vidéo dans la zone cliente. Des marges et non un rectangle : pendant un redimensionnement,
   Flutter n'a pas encore refait sa mise en page, et la vidéo doit déjà suivre le bord.
   Une minuterie Dart ne suit plus que la mise en page de Flutter (la place du widget).
4. Le widget perce un trou : il efface (`BlendMode.clear`) ce que Flutter a peint sous lui, et la
   fenêtre de l'app laisse voir ses pixels transparents (`SetWindowCompositionAttribute`, l'appel
   de `flutter_acrylic`). Le trou ne s'ouvre qu'une fois mpv en place, et la fenêtre de l'app
   redevient opaque dès que la surface disparaît.
5. Le client déclare `PlaybackCapabilities.mpvWindows` : le profil 5 reste en Direct Play
   (`dolbyVisionInDirectPlay`). `dolbyVision` reste faux — rien ne dit encore qu'un profil 5
   recopié en segments fMP4 garde de quoi appliquer sa RPU, donc une session à qualité réduite
   reste ré-encodée par le serveur.
6. Un moteur passé en fenêtre ne retourne pas au vestiaire (`PlayerEngine.reusable`) : la lecture
   suivante en construit un neuf, plutôt que d'hériter d'une sortie et de réglages d'écran qui
   n'étaient que pour ce fichier.

### Pourquoi le profil 5 seulement

Basculer toutes les lectures donnerait une vraie sortie HDR sous Windows, que la texture n'a pas.
Mais deux fenêtres synchronisées et une fonction Windows non documentée, c'est un risque qu'on ne
prend d'abord que pour les fichiers qui, sans ça, sortent roses ou ne se lisent pas du tout sur un
petit serveur. Élargir aux autres fichiers HDR revient à changer la condition de
`useDolbyVisionOutput` ; le SDR n'a rien à y gagner.

Écartés :

- **`wid`** (mpv dessine dans une fenêtre qu'on lui fournit) : il faudrait créer cette fenêtre
  avec une procédure et une boucle de messages à nous, donc du C++ dans le runner.
- **Recompiler mpv** pour un moteur `gpu-next` dans l'API de rendu : l'ADR-0019 a déjà dit ce que
  coûte une chaîne de build Windows.
- **`flutter_acrylic`** en dépendance : un plugin de plus pour un seul appel `user32`.

### Pourquoi le suivi est natif

Le premier essai suivait la fenêtre depuis une minuterie Dart. Pendant qu'on fait glisser une
fenêtre, Windows garde son fil dans une boucle modale et la minuterie ne tourne plus : seul le
chrome suivait la souris, et la vidéo se raccrochait au lâcher. Le message de fenêtre, lui, arrive
pendant le glissement.

Mesuré sur le banc (`prototypes/win_gpu_next`, 120 déplacements et 80 redimensionnements, la
position de la vidéo lue dès le retour de l'appel) : aucun écart.

Une fenêtre **enfant** aurait suivi sans aucun code — Windows déplace les enfants avec leur parent.
Essayée (`wid`, puis rangée sous la vue Flutter) : Windows ne mélange pas deux fenêtres sœurs. Sans
`WS_CLIPSIBLINGS` la vidéo recouvre toute l'interface, avec lui elle disparaît derrière.

## Conséquences

- Les deux fenêtres sont déplacées par deux appels successifs dans le même message : elles arrivent
  normalement dans la même image du compositeur, sans garantie absolue.
- Une transition qui passe par un calque (un fondu de page) referme le trou le temps qu'elle dure :
  l'effacement ne perce que son propre calque. Le lecteur montre alors son fond noir.
- `SetWindowCompositionAttribute` n'est pas documentée. Elle est stable depuis Windows 10 ; si elle
  disparaît, le trou sort noir et il faudra un autre moyen (une fenêtre en couches).
- Avec `target-colorspace-hint`, la fenêtre de mpv passe l'écran en HDR pendant que l'interface
  reste en SDR par-dessus : à juger sur un écran HDR.
- Reste à voir dans l'app : le plein écran, le multi-écran à densités différentes, l'enchaînement
  d'épisodes (le moteur est mis en commun), et l'animation d'entrée du lecteur.
- L'image reste rose pendant les ~130 ms qui séparent l'ouverture du fichier de l'arrivée des
  pistes : l'écran de chargement du lecteur les couvre.
- L'option de secours du menu Qualité (ADR-0060) n'apparaît plus sous Windows : le Direct Play y
  a les bonnes couleurs.

## Ajout — mpv déplace aussi sa fenêtre

À l'ouverture d'un fichier, mpv remet sa fenêtre à la taille de la vidéo. App agrandie, elle sortait
plus petite que le lecteur, avec une marge sur les côtés jusqu'au prochain redimensionnement.
Reproduit sur le banc (vue 1920×1009, marges demandées 60 : 43, −12, 43, −11 après l'ouverture).

Deux réponses : `auto-window-resize=no`, et la minuterie Dart vérifie à chaque passage que la
fenêtre de mpv occupe bien le rectangle demandé (`Win32VideoWindow.isInPlace`). Après correction,
les marges restent à 60 avant et après l'ouverture, app agrandie comme fenêtrée.
