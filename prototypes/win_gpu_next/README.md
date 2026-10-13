# Prototype jetable — mpv `gpu-next` derrière une fenêtre Flutter (Windows)

**Question :** une fenêtre mpv `vo=gpu-next`, glissée derrière une fenêtre Flutter transparente,
affiche-t-elle un Dolby Vision profil 5 avec les bonnes couleurs, avec des contrôles Flutter
par-dessus ? (Suite de l'ADR-0060 : sous Windows, la texture Flutter n'applique pas la couche RPU.)

Ce dossier n'est pas du code de production. Une fois la réponse connue, il se supprime.

## Lancer

```bash
cd prototypes/win_gpu_next
flutter run -d windows
```

Deux façons de choisir ce qui est lu :

- **Depuis le serveur** (ligne du haut) : l'adresse du serveur, le compte, le mot de passe, le
  numéro du média, puis « Lire du serveur ». Le prototype ouvre une session, demande un ticket de
  lecture et donne à mpv l'adresse du fichier tel quel (`/stream`), comme le Direct Play de l'app.
  Si le compte a la validation en deux étapes, un champ « Code » apparaît : le remplir et relancer.
- **Un fichier local** (ligne du bas) : son chemin, puis « Lire le fichier ».

Le numéro du média se lit dans le journal d'une lecture de l'app, sur la ligne
`startHlsSession … for media 7937` — 7937 est l'épisode profil 5 de l'essai du 13 octobre.

Le mot de passe reste en mémoire le temps du processus : rien n'est écrit sur le disque. Le ticket
de lecture vaut 15 minutes et n'est pas renouvelé — assez pour juger des couleurs, pas pour un
épisode entier.

Un clic sur l'image masque ou montre les contrôles.

## Ce qu'il faut regarder

1. **Les couleurs** sur l'épisode profil 5 : visages normaux, ou roses et verts ?
2. **La ligne de verdict** en bas : « Dolby Vision profil 5 — APPLIQUÉ » ou « NON appliqué ».
3. **La ligne d'état** : `vo=gpu-next`, le décodeur, `source → écran` (l'écran passe-t-il en PQ sur
   un moniteur HDR ?), les images perdues.
4. **La tenue de la fenêtre** : déplacement, redimensionnement, agrandissement, réduction,
   passage d'un écran à l'autre. La vidéo suit-elle, avec ou sans retard visible ?

Le journal complet de mpv est écrit dans `%TEMP%\onyx-proto-mpv.log`.

## Comment c'est fait

- `lib/main.dart` parle à `libmpv-2.dll` (celui de l'app, `packages/media_kit_libs_windows_video`)
  par `dart:ffi`, sans media_kit.
- mpv ouvre sa propre fenêtre, sans bordure et sans prise de focus. Une minuterie à 16 ms la colle
  sous la fenêtre Flutter, à la taille de sa zone cliente (`SetWindowPos`).
- La fenêtre Flutter est rendue transparente par `flutter_acrylic` ; le `Scaffold` est transparent
  dès qu'une vidéo joue.

## Déjà constaté (sur une mire HDR10 de synthèse, pas un profil 5)

- mpv démarre en `gpu-next` sur D3D11 avec décodage `d3d11va`, aucune image perdue.
- Les contrôles Flutter, semi-transparents, se dessinent bien par-dessus la vidéo.

## Limites connues du prototype

- La minuterie laisse la vidéo en retard d'une image ou deux pendant un déplacement de fenêtre.
- Rien n'est prévu pour le plein écran, les sous-titres, ni le choix des pistes.

## Banc du code de l'app

`lib/main_host.dart` fait tourner une copie de `MpvWindowHost` (le widget branché dans l'app,
ADR-0061) sur un fond noir Flutter, sans `flutter_acrylic` :

```bash
flutter run -d windows -t lib/main_host.dart -a "C:\chemin\vers\video.mkv"
```
