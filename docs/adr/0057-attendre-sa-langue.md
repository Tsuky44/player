# ADR-0057 — Attendre sa langue : une série suit les épisodes de la langue qu'on écoute

- **Statut :** accepté. Le Go et le Dart sont testés ; la carte n'a pas encore été vue tourner
  dans le lecteur, ni essayée à la télécommande.
- **Date :** 2026-10-12
- **Portée :** `server/indexer/audio_langs.go`, la table `media_audio_langs`,
  `server/handlers/awaited_language.go`, `server/handlers/continue_watching.go`,
  `server/handlers/next_up.go`, `server/handlers/show_track_preferences.go`,
  `app/lib/screens/player/playback/audio_language_gap.dart`,
  `app/lib/screens/player/hooks/use_episode_navigation.dart`,
  `app/lib/screens/player/hooks/player_controller_language.dart`,
  `app/lib/screens/player/widgets/language_gap_overlay.dart`,
  `app/lib/screens/player/playback/series_track_memory.dart`.
- **Prolonge :** [ADR-0044](0044-pistes-retenues-par-serie.md) (la langue retenue par série).

## Contexte

Un anime sort en VOSTFR, puis en VF environ trois semaines plus tard, sur le même épisode. Qui le
suit en VF ne savait plus où il en était :

- le lecteur enchaînait sur l'épisode suivant et, n'y trouvant pas de piste française, le jouait
  en japonais sans rien dire (le repli de l'ADR-0044) ;
- « Reprendre la lecture » proposait cet épisode en VO comme une nouveauté, puis ne signalait
  rien le jour où sa VF arrivait : pour le serveur, le fichier n'était plus neuf depuis des
  semaines.

Le serveur savait quelles langues un fichier porte (`tracks_json`), mais pas depuis quand.

## Décision

### 1. Le serveur date l'arrivée de chaque langue

`media_audio_langs` garde une ligne par média et par langue audio, datée du sondage qui l'a vue
pour la première fois. Un nouveau sondage ne touche pas aux langues déjà connues, date celles qui
apparaissent et retire celles qui ont disparu. Les médias sondés avant ce registre sont inscrits
au démarrage à partir des sondages stockés, sans ffprobe, et datés de leur entrée dans la
bibliothèque : ce que le serveur portait déjà n'est pas une nouveauté.

Le code de langue est celui que l'app retient pour une série (`normalizeLangCode`), et non celui
des sous-titres : c'est à ce code-là que les langues d'un épisode sont comparées. Les deux tables
sont épinglées par le même jeu de cas, de chaque côté.

### 2. Le lecteur demande avant d'enchaîner dans une autre langue

`GET /api/episodes/:id/next` joint les langues audio de l'épisode suivant. Au moment d'enchaîner
— compte à rebours du générique, fin du fichier, bouton « épisode suivant » — si cet épisode n'a
ni la langue qu'on entend ni celle qu'on a héritée, une carte de fin pose la question :
« L'épisode suivant n'est pas disponible en français. » avec deux réponses.

- **Continuer en japonais** : on enchaîne. La langue héritée reste le français, donc un épisode
  ultérieur qui l'a la retrouve sans question ; tant qu'on entend du japonais, les épisodes en
  japonais s'enchaînent sans redemander.
- **Attendre la version en français** : rien n'enchaîne, l'épisode en cours va à son terme, et
  le compte retient qu'il attend le français pour cette série.

Fermer la carte n'est pas une réponse : rien n'est retenu.

### 3. Le lecteur demande aussi au lancement

Un épisode lancé depuis l'accueil, la fiche ou le panneau des épisodes qui n'a pas la langue
suivie — celle retenue pour la série (ADR-0044), sinon la langue audio par défaut du compte
(ADR-0043) — se met en pause et pose la même question : « Cet épisode n'est pas disponible en
français. »

- **Continuer en japonais** : la lecture reprend. La réponse est retenue sur l'appareil, par
  saison, pour ne pas reposer la question à chaque épisode d'une série qui n'existe qu'en VO ;
  lire un épisode qui a la langue suivie l'efface, et le prochain épisode en retard redemande.
- **Attendre la version en français** : le compte retient l'attente, et le lecteur se ferme.

La question n'est pas posée à un épisode enchaîné depuis le précédent (elle l'a été au passage),
à un épisode repris en cours de route, ni en séance partagée.

### 4. « Reprendre la lecture » suit la langue attendue

La langue attendue vit avec les pistes de la série (`await_audio_lang`, ADR-0044). Tant qu'elle
est posée, et que l'épisode à reprendre n'est pas déjà entamé :

- il n'a pas cette langue → la série quitte la rangée : on est à jour dans sa langue ;
- il l'a, depuis moins de trois semaines et depuis la dernière fois que le compte s'est occupé de
  la série (l'avoir regardée, ou avoir dit attendre) → elle revient avec `has_new_episode`, en
  tête de rangée. La date qui compte est celle de la langue, pas celle du fichier.

Une série qu'on attend sans l'avoir jamais commencée — lancée, refusée en VO, quittée — n'a
aucune progression : elle entre dans la rangée le jour où son premier épisode existe dans la
langue attendue, et seulement tant que cette arrivée est une nouveauté.

« Entamé » se juge au seuil de la rangée (10 %) : les secondes passées devant la question ne
comptent pas.

L'attente se lève en répondant « continuer », ou en choisissant à la main une autre langue audio
dans la série. Elle ne se lève pas quand la VF arrive : la question se reposera au prochain
épisode en retard, et la série se cachera de nouveau si on y répond « attendre ».

## Conséquences

- Un compte sans langue audio par défaut, et sans langue retenue pour la série, n'est interrogé
  qu'au passage d'un épisode au suivant : au lancement, il n'y a pas de langue à comparer.
- Un compte qui n'a jamais répondu « attendre » garde l'ancien accueil.
- Un épisode entamé reste dans la rangée quelle que soit sa langue : c'est le compte qui l'a
  lancé.
- « Continuer » est retenu par appareil et par saison : un autre appareil repose la question.
- Un fichier sans langue déclarée, ou pas encore sondé, n'est jamais caché ni interrogé : le
  serveur ne peut pas affirmer qu'il lui manque une langue.
- Un compte qui n'attend aucune langue coûte une requête de plus sur `/api/home`, et rien d'autre.
- Hors ligne et sur un serveur plus ancien, la liste des langues manque : le lecteur enchaîne
  sans question. Le « attendre » répondu hors ligne part au retour du serveur, par la file de
  l'ADR-0044.
- La fiche de la série et son bouton « Reprendre » ne changent pas : seule la rangée de l'accueil
  suit la langue attendue.
