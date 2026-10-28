# ADR-0086 — Un mode léger pour les petits appareils, sans quitter le Direct Play

- **Statut :** proposé. Le Dart est analysé et testé ; le Swift des hôtes iOS et tvOS (`memoryProfile`)
  n'a pas encore été compilé, et rien n'a été mesuré sur une vraie Apple TV HD (voir « À vérifier »).
- **Date :** 2026-10-28
- **Portée :** `theme/lite_mode.dart`, `theme/frame_budget_watch.dart`, `services/device_hardware.dart`,
  le verre (`glass_chrome.dart` et les panneaux du lecteur), `AppMotion.reduced`, la transition de page
  TV (`tv_ui_scale.dart`), les ombres des affiches et du focus TV, le squelette, le cache d'images, et
  les options de dessin de mpv (`mpv_fast_rendering.dart`). Prolonge l'ADR-0025 et l'ADR-0076.

## Contexte

Sur une Apple TV HD (A8, 2 Go), l'interface rame — animations, défilement, focus — et un fichier 4K
lu en Direct Play saccade. La même chose est attendue sur un boîtier Android à 2 Go ou un Raspberry Pi.

Une première piste plafonnait la résolution par appareil et envoyait le 4K en HLS 1080p. Elle est
**écartée** : le but d'Onyx est le Direct Play, et un transcodage déplace la charge sur le serveur, qui
est souvent lui aussi une petite machine. Le fichier reste lu tel quel ; c'est tout le reste qui doit
coûter moins.

Ce qui coûte, à la lecture du code :

- **Le flou.** Chaque `BackdropFilter` relit, floute et repose ce qu'il couvre, à chaque image. L'en-tête
  au-dessus d'une page qui défile, les panneaux posés sur le film. C'était déjà le premier suspect sur
  les téléviseurs LG (ADR-0076), qui ne floutaient plus.
- **Le mouvement géométrique.** Le bandeau qui défile seul en plein écran toutes les quelques secondes,
  la transition de page TV (le glissé de Cupertino et son ombre sur Apple TV, le zoom de 450 ms sur
  Android TV), la dérive de l'aperçu « Reprendre ».
- **Les ombres floutées** : une par affiche, même transparente, plus le halo du focus TV.
- **Le squelette qui pulse** : tout l'écran redessiné pendant tout le chargement.
- **Le dessin de la vidéo par mpv** : sa mise à l'échelle par défaut passe plusieurs fois sur chaque
  pixel ; ramener du 4K vers un écran 1080p coûte alors à une petite puce plus que le décodage.

## Décision

### 1. Un mode léger, décidé avant la première image

`LiteMode` a la forme de `TvMode` : Auto, Activé, Désactivé (réglage « Mode léger », Général →
Affichage), un `ValueNotifier` republié par `LiteScope`. En Auto, il est actif quand :

- **le matériel le dit** (`isModestHardware`) : une Apple TV HD (`AppleTV5,x`), un téléviseur LG, un
  Android `isLowRamDevice` ou tout appareil mobile ou TV sous 2,5 Go de mémoire. Une Apple TV 4K garde
  tout. La mémoire et le modèle viennent d'un seul appel au canal `onyx/device` (`DeviceHardware`),
  désormais aussi sur iOS et tvOS, partagé avec `PlaybackProfiles` ;
- **ou les images le montrent** (`FrameBudgetWatch`) : en build de production, après dix secondes,
  une fenêtre de 180 images dont 30 % dépassent le budget d'une image (construction ou dessin). La
  mémoire ne dit pas tout : un Raspberry Pi à 4 Go a un tout petit processeur graphique. La mesure est
  gardée ; revenir à « Auto » l'efface et rejuge l'appareil.

### 2. Ce qu'il retire

- **Le flou**, partout : `glassBlurs(context)` est faux, le verre devient le voile dense déjà écrit
  pour les téléviseurs LG. Les panneaux posés sur le film passent par `GlassBlur`.
  `test/blur_respects_lite_mode_test.dart` refuse un flou qui ne demande pas `glassBlurs`.
- **Le mouvement géométrique** : `AppMotion.reduced` répond vrai, donc `AppMotion.move` vaut zéro, le
  bandeau ne défile plus seul et l'aperçu ne dérive plus. Les fondus restent.
- **Les ombres** des affiches et le halo du focus TV ; le zoom du focus reste, sans animation.
- **La pulsation du squelette**, figée.
- **Le cache d'images décodées** descend à 48 Mo : il dispute la mémoire au décodeur vidéo.

Hors mode léger, une seule chose change pour tout le monde : **la transition de page TV** devient celle
d'Onyx (fondu et légère montée). Le glissé de Cupertino portait le geste de retour du bord de l'écran,
qui n'existe pas à la télécommande, et la page du lecteur n'y subit plus aucune transformation.

### 3. La lecture reste en Direct Play

Le profil de lecture d'un appareil léger porte `fastRendering` : mpv met l'image à l'échelle en
bilinéaire, sans debanding, tramage ni sigmoïde, laisse au décodage logiciel ses raccourcis
(`vd-lavc-fast`, filtre de boucle sauté sur les images non référencées) et lâche une image en retard
plutôt que de ralentir (`framedrop=decoder+vo`). Le décodage matériel reste le choix de l'utilisateur.

Ce profil est fixé au démarrage : le moteur est mis en commun et garde ses options d'une lecture à
l'autre. Changer le réglage vaut tout de suite pour l'interface, et pour la vidéo au démarrage suivant.

AetherEngine (Apple) et ExoPlayer (Android) choisissent seuls leur rendu : le mode léger n'y touche que
ce qui est posé sur le film, et le tampon d'ExoPlayer suit déjà le profil `constrained`.

## Conséquences

- Sur un petit appareil, l'interface est plus plate : pas de verre, pas d'ombre, pas de défilement
  automatique du bandeau. Rien de ce qui se lit ne disparaît.
- Un appareil puissant qui saccade un moment (un portable sur batterie) peut passer en mode léger de
  lui-même et le rester. Le réglage dit pourquoi, et « Auto » le rejuge.
- Une nouvelle animation géométrique passée par `AppMotion.move` est retirée en mode léger sans rien
  écrire ; une durée brute ne l'est pas — raison de plus pour convertir les ~110 qui restent.

## À vérifier

- Compiler les hôtes iOS et tvOS : `memoryProfile` y est nouveau.
- Sur une Apple TV HD : que l'app démarre en mode léger, que le défilement de l'accueil et le focus
  suivent la télécommande, et qu'un 4K en Direct Play saccade moins avec le chrome affiché.
- Sur un Raspberry Pi (Android TV ou navigateur) : que la mesure des images bascule bien, et pas sur
  un ordinateur ordinaire.
- Si AetherEngine expose un jour un réglage de rendu (mise à l'échelle, abandon d'images), le brancher
  sur `fastRendering`.
