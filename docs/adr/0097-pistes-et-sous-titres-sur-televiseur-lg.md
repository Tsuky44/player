# ADR-0097 — Sous-titres et pistes audio sur un téléviseur LG : la liste du serveur, la langue pour désigner

- **Statut :** accepté, non encore essayé sur un téléviseur
- **Date :** 2026-10-30
- **Portée :** `PlayerController.listsEmbeddedSubtitles`
  (`player_controller_tracks.dart`), `onyx_settings_menu.dart`,
  `audio_track_pairing.dart`, `LiveSubtitleFeed.showCues` (`live_subtitles.dart`).
- **Complète** l'ADR-0076 (téléviseurs LG par l'app web) et l'ADR-0031 (sous-titres vivants).

## Contexte

Sur un téléviseur LG, deux pannes : le menu des sous-titres restait vide, et certaines
langues audio étaient échangées (le français demandé donnait l'anglais).

- Le menu du lecteur lisait ses sous-titres de Direct Play sur le moteur (`session.subtitleTracks`).
  Le `<video>` de webOS n'en voit aucun (ADR-0076) : la liste était toujours vide, alors que le
  contrôleur, lui, savait déjà s'appuyer sur les WebVTT du serveur (`_readsEmbeddedSubtitles`).
  Le même test mal placé faisait oublier le sous-titre actif à l'épisode suivant, et empêchait
  d'attendre l'extraction d'une piste pas encore prête.
- Le choix de la piste audio se faisait par rang : la n-ième du serveur était la n-ième de
  l'élément (ADR-0076). Le pipeline du téléviseur ne garantit pas l'ordre du conteneur.

## Décision

1. La source des sous-titres proposés se décide à un seul endroit,
   `listsEmbeddedSubtitles` : ceux du fichier tels que le moteur les liste, ou ceux du serveur.
   Le menu, le bouton « sous-titres », l'attente d'extraction et l'héritage d'un épisode à
   l'autre la lisent, au lieu de tester `currentQuality == null`.
2. En Direct Play, la piste audio du moteur se désigne par la langue
   (`engineAudioTrackFor`), le rang parmi les pistes de même langue départageant les doublons.
   Si la langue n'est pas lisible ou si les comptes divergent, on retombe sur le rang, comme avant.
3. Sur webOS, les répliques sont peintes par Flutter (`LiveSubtitleFeed.showCues`), comme celles
   d'une session HLS, et non par un `<track>` : le `<video>` d'un téléviseur est dans le plan
   vidéo matériel, où ce que le navigateur dessine pour lui n'est pas garanti. Le plein écran
   natif, pour lequel le `<track>` avait été choisi sur le web, n'existe pas sur un téléviseur.

## Conséquences

- Les sous-titres du serveur se choisissent au menu sur LG, Direct Play comme HLS.
- Sur le web de bureau, l'épisode suivant retrouve lui aussi le sous-titre choisi (le moteur n'y
  liste rien non plus).
- À confirmer sur un appareil : l'ordre des `audioTracks` de webOS et la langue qu'il annonce.
  Si elle manque, le comportement reste celui d'avant (le rang).
- Non traité ici : le menu de qualité cache « Le fichier tel quel » sur tout le web, webOS compris.
