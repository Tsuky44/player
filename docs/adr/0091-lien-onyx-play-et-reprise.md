# ADR-0091 — `onyx://play` : « Lire sur Onyx » depuis MediaHub, avec reprise

- **Statut :** accepté
- **Date :** 2026-10-29
- **Portée :** l'app (`app/lib/navigation/play_link.dart`, `main.dart`,
  `screens/shell/main_shell.dart`, `screens/library/movie_detail_screen.dart`,
  `screens/library/show_detail_screen.dart`, `services/api/media.dart`, manifestes
  Android, iOS et macOS). Côté MediaHub : le bouton « Lire sur Onyx » des comptes liés à Onyx.

## Contexte

MediaHub propose « Lire sur Emby » ou « Lire sur Jellyfin » qui ouvre l'app du serveur.
Un compte lié à Onyx n'avait rien d'équivalent, et Onyx n'avait aucun lien de lancement
(l'ADR-0073 ne couvre que le web, par `?movie=` et `?show=`). MediaHub ne connaît que les
identifiants TMDB, pas ceux de la bibliothèque d'Onyx.

## Décision

- **Contrat du lien :** `onyx://play?tmdbId=<id>&type=movie|tv`. `show` est accepté comme
  synonyme de `tv`. Tout autre schéma, action ou paramètre manquant ou invalide est ignoré.
- **Réception :** le paquet `app_links` lit le lien qui a lancé l'app et ceux reçus app
  ouverte. Le schéma `onyx` est déclaré dans `AndroidManifest.xml` (VIEW, BROWSABLE) et dans
  les `Info.plist` iOS et macOS.
- **Attente de session :** comme `MediaLink` et `TvPairingLink`, le lien est gardé dans
  `PlayLink.pending` jusqu'à ce que la coquille soit prête (donc connectée), puis consommé
  une seule fois.
- **Résolution :** `GET /api/library/tmdb-index` (ADR-0073) donne l'identifiant de la
  bibliothèque. Titre absent ou serveur injoignable : message à l'écran, pas de plantage.
- **Lecture :** la fiche s'ouvre avec `autoPlay`. Un film se lance, le lecteur relisant sa
  position sauvegardée. Une série lance l'épisode de `GET /api/shows/:id/resume` (épisode en
  cours, sinon le suivant non vu), à défaut le premier épisode lisible. Aucune logique de
  reprise nouvelle.

## Conséquences

- Windows, Linux et tvOS ne déclarent pas le schéma : le lien n'y fait rien.
- Une version d'un film en plusieurs versions joue la plus ancienne fiche, comme l'index TMDB.
