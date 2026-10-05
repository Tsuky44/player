# ADR-0044 — La langue audio et le sous-titre se retiennent par série

- **Statut :** accepté. Le Go et le Dart sont testés ; le passage d'un appareil à l'autre n'a pas
  encore été essayé sur deux vrais appareils.
- **Date :** 2026-10-05
- **Portée :** `server/handlers/show_track_preferences.go`, la table `user_show_track_preferences`,
  `app/lib/screens/player/playback/series_track_memory.dart`,
  `app/lib/screens/player/player_playback_preferences.dart`.

## Contexte

Le choix d'une langue audio et d'un sous-titre ne vivait que dans la séance de lecture : le lecteur
le passait à l'épisode suivant en mémoire, et il disparaissait dès qu'on le quittait. Régler une
série en « anglais, sous-titres français complets » était à refaire à chaque reprise, et sur chaque
appareil. La langue audio par défaut du compte (ADR-0043) ne répond pas à ce besoin : elle vaut pour
toute la bibliothèque, alors qu'on regarde un anime en japonais et une sitcom en anglais.

Dans la séance elle-même, la piste audio se transmettait par son **rang** : quand l'ordre des pistes
changeait d'un fichier à l'autre, le même rang désignait une autre langue.

## Décision

**Le choix fait à la main dans un épisode appartient à la série, sur le compte.**

Une ligne par compte et par série, écrite au moment où l'on choisit une piste dans le lecteur. À
l'ouverture d'un épisode sans choix transmis par l'épisode précédent, le lecteur lit cette ligne et
l'applique exactement comme un choix hérité.

- **On retient une description, pas un rang ni une clé.** L'audio par sa langue. Le sous-titre par
  sa langue, forcé ou complet, texte ou image — la clé (`fr2`) n'est gardée que pour départager.
  C'est ce qui permet de retrouver « le plus proche » dans un fichier découpé autrement.
- **« Désactivés » est un choix**, distinct de « rien de choisi » : il suit lui aussi.
- **Quand l'épisode n'a pas ce qu'on veut**, l'audio retombe sur la langue par défaut du compte puis
  sur la piste du fichier ; le sous-titre n'affiche rien plutôt qu'une piste d'un autre type. Le
  choix retenu ne change pas pour autant : l'épisode d'après le retrouve.
- **Les routes prennent l'épisode** (`GET` et `PUT /api/episodes/:id/track-preferences`) : c'est le
  serveur qui sait à quelle série il appartient, doublons d'indexation compris.
- **L'appareil garde une copie**, rangée par saison faute de connaître la série sans le serveur.
  Elle sert si le serveur ne répond pas en 700 ms — la demande court pendant celle du ticket de
  lecture — et tout de suite pour un épisode téléchargé. Un choix qui n'a pas pu partir y est noté
  et part avant la prochaine lecture du compte, comme dans l'ADR-0043.

Cette décision **complète l'ADR-0043** : la langue audio par défaut du compte reste le repli de
toute série où l'on n'a rien choisi.

## Conséquences

- Un film ne retient rien : son réglage n'a pas de suite à qui se transmettre.
- Seul un choix fait à la main est retenu. Une piste que le lecteur prend de lui-même (repli, piste
  par défaut du fichier) ne devient pas la préférence de la série.
- Une piste audio sans langue déclarée n'est pas retenue : rien ne permettrait de la retrouver.
- Deux appareils qui changent le même réglage hors ligne : le dernier à retrouver le serveur gagne.
- Hors ligne, une saison jamais ouverte sur cet appareil démarre sans le choix de la série.
- Un serveur plus ancien répond 404 : le lecteur garde alors le seul passage d'un épisode au
  suivant, et la copie locale.
