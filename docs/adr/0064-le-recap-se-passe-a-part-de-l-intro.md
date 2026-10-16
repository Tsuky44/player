# ADR-0064 — Le récap se passe à part de l'intro

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** le bouton « Passer » du lecteur —
  `app/lib/screens/player/playback/skip_segments.dart`,
  `app/lib/screens/player/hooks/use_episode_navigation.dart`,
  `app/lib/screens/player/widgets/onyx/onyx_skip_intro_button.dart` ; le réglage
  `auto_skip_recap` (`server/handlers/playback_preferences.go`, migration 23,
  `app/lib/services/playback_preferences_storage.dart`) ; les mots-clés d'intro de
  `server/indexer/detection.go`.
- **Prolonge** l'[ADR-0043](0043-reglages-de-lecture-lies-au-compte.md) : le nouveau réglage
  appartient au compte, comme le saut d'intro.

## Contexte

Un épisode dont les chapitres MKV sont « Recap », « Intro », « Chapter 1 », « Credits » ne
proposait qu'un « Passer l'intro », qui sautait le récap. La détection des chapitres (serveur et
client) rangeait « recap » et « previously on » parmi les titres d'intro et gardait le premier
chapitre trouvé : le récap prenait la place de l'intro, qui n'était jamais proposée.

## Décision

**Deux propositions successives, chacune avec son réglage.**

- Le client classe un chapitre en récap ou en intro (`ChapterTitles`), jamais les deux. Pendant
  le récap, le bouton dit « Passer le récap » et saute à sa fin ; pendant l'intro, « Passer
  l'intro ». Le même bouton, le même compte à rebours, le même gel au moindre geste.
- « Passer le récap automatiquement » est un réglage distinct de « Passer l'intro
  automatiquement », éteint par défaut, synchronisé avec le compte (`auto_skip_recap`).
- Le récap ne vient que des chapitres : ni TheIntroDB ni la base ne le rangent à part. Le serveur
  ne range plus un chapitre « Recap » comme intro.
- Une intro de la base qui ne déborde pas du récap — fusion TheIntroDB récap + intro, ou ligne
  écrite avant ce changement — est ignorée quand un récap est connu : ce sont les chapitres qui
  donnent l'intro.

## Conséquences

- Un épisode sans chapitres mais avec TheIntroDB garde un seul « Passer l'intro » qui saute
  récap et intro ensemble : la base n'a qu'une plage.
- Un client plus récent qu'un serveur sans `auto_skip_recap` garde le réglage de l'appareil.
