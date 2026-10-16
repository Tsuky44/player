# ADR-0063 — Trois modes d'affichage, tous par zoom, sur toutes les plateformes

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** le cadrage de l'image dans le lecteur —
  `app/lib/screens/player/video_display_mode.dart`, `app/lib/screens/player/pinch_zoom_fit.dart`,
  `app/lib/screens/player/playback/native_video_framing.dart`,
  `app/lib/screens/player/playback/aether_video_fit.dart`,
  `app/lib/screens/player/playback/mpv_native_surface.dart`,
  `app/lib/screens/player/playback/texture_video_surface.dart`, la section « Affichage » de
  `app/lib/screens/player/widgets/onyx/onyx_settings_menu.dart`.
- **Remplace** la règle qui faisait dessiner « Original » en « remplir la hauteur » sur un
  téléphone (`VideoFitRendering`, supprimé). **Prolonge** l'[ADR-0035](0035-avplayer-en-recopie-sur-iphone-et-mac.md)
  et l'[ADR-0038](0038-aetherengine-sur-les-appareils-apple.md), dont le cadrage par la couche
  vidéo reste celui d'Apple.

## Contexte

Le lecteur offrait deux réglages, « Original » et « Adaptatif ». Sur un téléphone, « Original »
ne voulait pas dire la même chose qu'ailleurs : il remplissait la hauteur, en silence. Il n'y avait
donc aucun moyen d'avoir le letterbox sur un téléphone, ni de supprimer seulement les bandes du
haut et du bas sur un téléviseur ou un ordinateur. Et sur macOS, mpv ramenait tout cadrage autre
que `cover` à l'image entière : « remplir la hauteur » n'y existait pas.

La demande : un mode qui supprime toutes les bandes noires, un mode qui ne supprime que celles du
haut et du bas, sans jamais déformer l'image.

## Décision

**Trois modes, nommés par ce qu'ils font, identiques sur toutes les plateformes.**

| Mode | `BoxFit` | Ce qui disparaît |
|---|---|---|
| Original | `contain` | rien : l'image entière, bandes là où il le faut |
| Remplir la hauteur | `fitHeight` | les bandes du haut et du bas ; les côtés d'un film plus large que l'écran sortent |
| Remplir l'écran | `cover` | toutes les bandes ; ce qui dépasse est rogné |

1. **Rien ne s'étire.** Chaque mode est un zoom qui garde le rapport de l'image ; `BoxFit.fill`
   n'est proposé nulle part. `video_display_mode_test.dart` le vérifie mode par mode.
2. **Le choix est explicite, le défaut dépend de l'appareil.** Tant que l'utilisateur n'a rien
   choisi, un téléphone part en « Remplir la hauteur » (ce qu'il faisait déjà), une tablette, un
   téléviseur et un ordinateur en « Original ». L'écran garde `null` pour « pas encore choisi »,
   et le transmet tel quel à l'épisode suivant.
3. **Un pincement avance d'un cran** dans l'ordre Original → Remplir la hauteur → Remplir
   l'écran, et revient d'un cran dans l'autre sens.
4. **Chaque moteur reçoit le même `BoxFit`** :
   - ExoPlayer (Android, Android TV) a les trois en natif (`CONTAIN`, `FILL_HEIGHT`, `COVER`).
   - La texture de media_kit (Windows, web) les applique par `FittedBox`, et sa taille suit
     désormais l'image *cadrée* : une texture taillée à l'image entière était agrandie, donc floue,
     dès qu'on zoomait.
   - AetherEngine (iOS, tvOS, macOS) et mpv dans sa propre vue (macOS, Dolby Vision sous Windows)
     n'ont que « image entière » ou « vue remplie ». `NativeVideoFraming.crops` ramène tout cadrage
     à l'un des deux d'après la forme de l'image et de la vue : « Remplir la hauteur » d'un film
     plus large que l'écran le remplit, d'un 4:3 il le laisse entier.

## Conséquences

- « Adaptatif » disparaît de l'interface ; ses traductions aussi.
- Le choix ne survit pas à la fermeture du lecteur : il suit les épisodes enchaînés, pas les
  sessions. Le mémoriser par appareil serait une décision à part.
- Les bandes noires **incrustées dans le fichier** (un film 2.39 encodé en 16:9 avec ses bandes)
  ne sont pas détectées : pour le lecteur, elles font partie de l'image. « Remplir l'écran » ne les
  enlève donc pas. Les supprimer demanderait une détection de recadrage (`cropdetect`), que seul
  mpv sait faire.
