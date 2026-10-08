# ADR-0052 — Des fichiers découpés par sujet, et une limite qui tient

- **Statut :** accepté. Analyse et tests verts des deux côtés. **Le lecteur n'a pas été relancé sur
  un appareil après son découpage** : aucun test ne monte `PlayerScreen`, qui a besoin d'un moteur
  natif.
- **Date :** 2026-10-08
- **Portée :** `app/lib/screens/player/player_screen*.dart`,
  `app/lib/screens/player/hooks/` (`use_player_controller.dart`, `player_controller_*.dart`,
  `use_episodes_panel.dart`, `use_gesture_hints.dart`, `use_playback_handoff.dart`,
  `use_player_popup.dart`, `use_player_watch_party.dart`),
  `app/lib/screens/player/player_key_routing.dart`, `player_media_info.dart`, `pinch_zoom_fit.dart`,
  `app/lib/screens/player/widgets/` (`player_popups.dart`, `player_tap_zones.dart`,
  `player_video_stage.dart`), `app/lib/models/`, `app/lib/services/api_client.dart`,
  `app/lib/services/api/` (`media.dart`, `playback.dart`), `server/handlers/emby_*.go`,
  `server/handlers/federation*.go`, `server/codeguard/`, `app/test/file_size_guard_test.dart`,
  `app/test/no_silent_catch_test.dart`, `app/test/no_dart_io_outside_io_files_test.dart`.

## Contexte

Six fichiers concentraient l'essentiel des changements et de leurs régressions :
`player_screen.dart` (3 200 lignes), `use_player_controller.dart` (2 300), `models.dart` (1 700),
`api_client.dart` (1 200), `emby_sync.go` et `federation.go` (1 100 et 1 000). La règle « pas de
fichier au-dessus de 800 lignes » existait, écrite, et rien ne la vérifiait.

Deux autres conventions tenaient de la même façon, par la seule relecture : `dart:io` hors des
fichiers `_io.dart` casse la version web, que ni l'analyse ni les tests ne construisent ; et 33
`catch` vides avalaient une erreur sans dire pourquoi.

## Décision

1. **Ce qui a un état et une interface étroite devient une classe à part.** Sortis de l'écran du
   lecteur : le panneau des épisodes (`EpisodesPanelController`), la reprise sur un autre appareil
   (`PlaybackHandoffWatch`), la séance « Regarder ensemble » (`PlayerWatchParty`), les menus
   (`PlayerPopupHost`), les indications de geste (`GestureHints`), le pincement (`PinchTracker`),
   les titres du média (`PlayerMediaInfo`), et trois widgets passifs. L'écran leur donne des
   fonctions, pas lui-même.
2. **La décision d'une touche est une fonction pure.** `routePlayerKey` rend une `PlayerKeyAction` ;
   l'écran l'exécute. Clavier et télécommande se testent sans monter l'écran.
3. **Ce qui reste lié à l'état de l'écran est rangé par sujet dans des fichiers `part`**, en
   extensions sur cet état : `player_screen_chrome.dart`, `_remote.dart`, `_startup.dart`,
   `_flow.dart`. Même découpage pour `PlayerController` (`player_controller_startup.dart`, `_hls.dart`,
   `_tracks.dart`). Les champs restent dans la classe ; une extension appelle `_update`, puisque
   `setState` est protégé.
4. **Les modèles sont rangés par domaine** dans `models/` ; `models.dart` ne fait que les
   réexporter. `ApiClient` perd deux domaines de plus au profit de mixins `part of`
   (`api/media.dart`, `api/playback.dart`), comme les précédents.
5. **Côté serveur, `emby_sync.go` et `federation.go` sont découpés par étage**, dans le même
   package : aucun nom ne change.
6. **La limite est un test.** `file_size_guard_test.dart` et `codeguard/size_test.go` refusent un
   fichier au-dessus de 800 lignes. Ceux qui y sont encore figurent dans une liste, chacun avec le
   plafond qu'il ne doit plus dépasser ; un fichier repassé sous la limite doit en sortir.
7. **Deux autres conventions deviennent des tests** : `dart:io` et `Platform.isX` seulement dans
   les fichiers `_io.dart` ; aucun bloc qui avale une erreur sans instruction ni commentaire. Les
   33 blocs existants ont reçu leur raison.

## Alternatives écartées

- **Tout extraire en classes.** Le chrome, le focus de la télécommande et l'enchaînement des
  épisodes lisent et écrivent les mêmes drapeaux (`_showControls`, `_isLeaving`,
  `_wantsPlayback`). Les séparer demande de redessiner cet état, pas de déplacer du code : un
  changement de comportement, à faire avec un lecteur sous les yeux.
- **Des mixins plutôt que des extensions** pour l'état de l'écran. Un mixin doit redéclarer chaque
  champ qu'il lit, et les quatre sujets se partagent presque tous les champs de l'état.
- **Une limite sans liste de tolérés.** Il aurait fallu découper dix fichiers de plus dans le même
  changement, sans pouvoir en vérifier le comportement.

## Conséquences

- Un fichier `part` n'isole rien : les extensions voient tous les champs privés de l'état. Le
  découpage rend le lecteur lisible par sujet, il ne le rend pas plus sûr à modifier. Le pas
  suivant, pour un sujet donné, est le point 1.
- Restent au-dessus de la limite, plafonnés : `onyx_controls_layer.dart`,
  `download_manager_io.dart`, `servers_screen.dart`, `show_detail_screen.dart`, `settings_ui.dart`,
  `mpv_playback_session.dart` ; `indexer/metadata.go`, `indexer/monitor.go`, `handlers/activity.go`.
  `l10n/en.dart` et `database/migrations.go` en sont exemptés : ce sont des listes.
- `no_offscreen_polling_test.dart` suit maintenant les fichiers `part` jusqu'à leur bibliothèque :
  la minuterie du relais, passée dans `player_screen_startup.dart`, y reste déclarée. Celle de la
  reprise sur un autre appareil vit dans `PlaybackHandoffWatch`, qui n'est pas un écran : ce test
  ne la voit plus, comme il ne voit aucun hook.
