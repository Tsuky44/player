# ADR-0077 — Les administrateurs sont notifiés des nouvelles demandes, par la tâche des épisodes passée au quart d'heure

- **Statut :** accepté, en cours. Serveur et Dart testés. **Aucune notification n'a encore été
  vue arriver sur un appareil**, et le Swift de l'`AppDelegate` n'a été compilé sur aucun Mac.
- **Date :** 2026-10-21
- **Portée :** le serveur (`MediaHubRequestFeed` dans `server/handlers/mediahub.go`, la route
  `GET /api/requests/feed` dans `server/main.go`, `contract/onyxhub/request_feed.json`) et l'app
  (`app/lib/services/request_alerts/`, `app/lib/services/api/request_feed.dart`,
  `app/lib/models/request_feed.dart`, `app/lib/services/notifications/onyx_notifications.dart`,
  `app/lib/services/new_episodes/new_episode_alerts.dart`,
  `app/lib/screens/settings/widgets/new_episode_alerts_group.dart`,
  `app/ios/Runner/AppDelegate.swift`). Côté OnyxHub : son ADR-0013.
- **Prolonge :** [ADR-0059](0059-notifications-de-nouveaux-episodes.md), dont il change le rythme
  de la tâche de fond.

## Contexte

L'administrateur d'un serveur veut une notification quand un compte demande un média : le
titre, les saisons d'une série, et le nom du compte. Les demandes vivent chez OnyxHub ; l'app ne
lui parle qu'à travers le serveur (ADR-0073). Et il n'y a pas de push (ADR-0059 §1).

## Décision

### 1. Le serveur relaie un flux, réservé à `manage_settings`

`GET /api/requests/feed?after=<curseur>` relaie `GET {OnyxHub}/api/request/feed`. Le flux
contient les demandes de **tous** les comptes : il est réservé à `manage_settings`, le droit
qu'OnyxHub prend pour « administrateur ». Le serveur ne transmet que le curseur, validé comme
entier. OnyxHub rend `{ cursor, requests[] }`, tait les demandes de l'appelant, et, sans curseur,
pose le curseur au bout sans rien rendre.

### 2. L'app garde un curseur par compte

`RequestAlertWatch` interroge chaque compte du carnet avec le curseur de son dernier passage
(`RequestFeedLedger`, dans les préférences comme `NewEpisodeLedger`).

- Un compte qui répond 403, 404, 405 ou 503 n'a pas de flux (pas administrateur, serveur ancien,
  OnyxHub non réglé) : son curseur est oublié, et s'il en retrouve un, ce sera un premier
  passage. Le serveur n'a pas de capacité dans `/api/ping` pour ça : la tâche de fond ne paierait
  pas un aller-retour de plus pour apprendre ce que le 404 dit déjà.
- Un serveur muet (réseau, 502) garde son curseur : le passage suivant rattrape.
- La notification : « Nouvelle demande de *nom* », puis « *titre* · Saisons 1, 2 » ou
  « *titre* · Film », et le serveur s'il y en a plusieurs. La toucher ouvre l'app, sans plus.
- L'affiche TMDB (w342) est téléchargée par l'appareil au moment de notifier
  (`NotificationPoster`, 6 s au plus) : en vignette et en grand une fois dépliée sur Android, en
  pièce jointe sur iPhone, qui ne prend qu'un fichier. Si elle n'arrive pas, la notification part
  sans elle.

### 3. Une seule tâche de fond, au quart d'heure

Les deux veilles partagent la tâche `com.tsuky.onyx.new-episodes` : iOS n'en réveille qu'une, à
l'heure qu'il choisit, et l'identifiant est déjà dans l'`Info.plist`. Son intervalle passe d'une
heure à **15 minutes**, le plancher de WorkManager (et `earliestBeginInSeconds` sur iOS).

Contredit l'ADR-0059 sur le rythme parce qu'une demande attend une réponse d'un humain : une
heure, c'est long pour qui vient de demander un film pour le soir. Les épisodes, eux, **gardent
leur heure** : la tâche ne les refait qu'une fois sur quatre (`episodesDue`), `/api/home` étant
plus lourd que le flux.

La planification passe de `keep` à `update` : `keep` aurait laissé l'intervalle d'une heure aux
installations existantes. `update` garde l'heure du prochain passage, donc relancer l'app ne le
repousse toujours pas.

### 4. Un seul fichier connaît `flutter_local_notifications`

`NewEpisodeNotifications` devient `OnyxNotifications` (`services/notifications/`) : le plugin
s'initialise une fois par isolat avec un seul rappel, deux classes ne pouvaient pas l'initialiser
chacune. Les demandes ont leur canal Android, `new_requests`, réglable à part.

`NewEpisodeAlerts` garde son nom bien qu'il planifie aussi les demandes : le renommer touchait
`main.dart`, les réglages et les tests pour rien de plus.

### 5. Un interrupteur de plus, pour les administrateurs

*Réglages → Cet appareil → Notifications* montre « Nouvelles demandes » quand le compte actif a
`manage_settings`. Allumé par défaut. L'app ouverte annonce aussi les demandes du serveur actif :
aucune pastille ne les montre déjà.

## Conséquences

- La tâche de fond tourne quatre fois plus souvent : un appel au flux par compte et par quart
  d'heure (un 403 pour un compte qui n'administre rien), `/api/home` toujours une fois par heure.
- La notification arrive dans le quart d'heure sur Android ; sur iPhone quand iOS le décide, et
  à l'ouverture de l'app.
- Les constructeurs Android qui tuent les tâches de fond (ADR-0059) retardent aussi celle-ci.
- Le nom du compte voyage jusqu'au volet de notifications du téléphone de l'administrateur.
