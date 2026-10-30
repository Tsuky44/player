# ADR-0096 — La langue audio et le sous-titre se retiennent aussi par film

- **Statut :** accepté. Le Go et le Dart sont testés ; le passage d'un appareil à l'autre n'a pas
  été essayé sur deux vrais appareils.
- **Date :** 2026-10-30
- **Portée :** `server/handlers/show_track_preferences.go`, la table `user_show_track_preferences`,
  `app/lib/screens/player/playback/series_track_memory.dart`.
- **Prolonge :** [ADR-0044](0044-pistes-retenues-par-serie.md).

## Contexte

L'ADR-0044 ne retenait rien pour un film : son réglage n'avait « pas de suite à qui se transmettre ».
C'était oublier la reprise. Un film commencé en anglais sous-titré, quitté puis repris le lendemain
(ou sur un autre appareil), repartait avec la langue par défaut du compte.

## Décision

**Un film retient son propre choix, sur le compte, comme une série.**

- Même table, même route (`GET` et `PUT /api/episodes/:id/track-preferences`), mêmes règles de
  validation : pour un film, la ligne est rangée sous l'identifiant du film dans `show_id`
  (une clé étrangère vers `medias`, qui accepte un film). Pas de migration.
- Le choix n'est partagé ni avec un autre film ni avec une série.
- Sur l'appareil, la copie locale d'un film est rangée sous son identifiant (`m<id>`), non par saison.
- Mêmes repli et même file d'envoi que pour une série (délai de 700 ms, choix noté avant l'envoi).

## Conséquences

- Le nom de la route et de la colonne (`episodes`, `show_id`) ne dit plus tout : ils couvrent aussi
  les films. Les renommer casserait les serveurs et les apps déjà installés.
- Un film supprimé emporte sa ligne (`ON DELETE CASCADE`).
- Un film dont l'identifiant change à la ré-indexation perd son choix : il n'y a pas de film
  « canonique » comme il y a une série canonique.
- Un serveur plus ancien répond 404 pour un film : le lecteur garde alors la copie locale.
- L'attente d'une langue (ADR-0057) ne s'applique toujours qu'aux séries.
