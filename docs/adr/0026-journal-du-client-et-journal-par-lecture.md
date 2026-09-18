# ADR-0026 — Le journal du client, et celui de chaque lecture

- **Statut :** proposé. Le client est en place (`flutter analyze` propre, 417 tests dont 7 neufs
  pour `ClientLog`) ; le serveur n'a pas été compilé, faute de toolchain Go sur la machine où le
  changement a été écrit — voir « À vérifier ».
- **Date :** 2026-09-18
- **Portée :** la capture des traces côté client (`client_log.dart`), la page Journal des réglages,
  la table `playback_logs` et ses deux routes, et la règle qui décide qu'une lecture reste dans
  l'historique. Rien de la chaîne de lecture : ni le choix Direct Play / HLS, ni le transcodage.

## Contexte

Une panne de lecture sur Android ne disait rien. L'ADR-0009 place ExoPlayer derrière le même port
que mpv, et ce port n'avait pas de canal pour une panne : `ExoPlaybackSession` recevait bien les
instantanés du natif, `errorKind` et `errorMessage` compris, et ne les lisait pas. Toute panne
sortait donc par le même chemin — l'écran de démarrage attendait vingt-cinq secondes puis affichait
« La lecture ne démarre pas », qui nomme le réseau, quelle qu'ait été la cause.

L'application diagnostiquait pourtant abondamment : capacités de l'appareil, décodeur retenu, palier
demandé, erreurs d'API. Tout cela partait dans `debugPrint`, c'est-à-dire dans la console du
développeur. Sur un APK installé, cette console demande un câble, un pilote et un mode
développeur ; sur le téléviseur du salon, elle n'existe pas. « Ça ne se lance pas » restait tout ce
qu'on pouvait savoir.

## Décision

**Trois couches, de la plus proche de la panne à la plus durable.**

**1. Le moteur dit ses pannes.** `PlaybackSession` gagne un flux `failures` et un type
`PlaybackFailure` à trois cas. `unsupported` avant la première image bascule en HLS — le repli que
le commentaire de `OnyxPlayerErrorKind` promettait et que personne n'avait branché ; les autres
remontent à l'écran, avec le message brut du moteur sous l'explication. mpv ne s'y branche pas :
media_kit publie ses erreurs sur un flux qui porte aussi des lignes sans gravité, et trier ce flux
est un autre chantier.

**2. Le client garde ce qu'il écrit.** `ClientLog` détourne `debugPrint` au premier appel de `main`
et garde six cents lignes en mémoire, plus `FlutterError.onError` et les erreurs asynchrones non
rattrapées. Rien n'est écrit sur le disque. Réglages → Journal les montre et les copie.

La gravité est **écrite, pas devinée** : chercher « erreur » ou « failed » dans une chaîne rate ce
qui est écrit autrement et se trompe sur une ligne qui cite le mot. Une ligne est une erreur parce
que le code est passé par `ClientLog.error`.

**3. Chaque lecture laisse son journal au serveur.** Le client marque le rang de sa première ligne à
l'ouverture, prélève la tranche à l'arrêt, et l'envoie **avant** le signal d'arrêt : le serveur la
rattache à la séance encore ouverte, et c'est ce signal qui la ferme. L'ordre inverse écrirait dans
le vide. Une ligne de `playback_logs` par lecture, remplacée en bloc, bornée à trois cents lignes et
128 Kio, et la table entière aux trois cents dernières lectures.

## Ce que cela change à l'historique

Une lecture de moins de trente secondes était effacée comme une ouverture accidentelle. Elle l'est
toujours — **sauf si son journal porte une erreur**. Une lecture qui n'a jamais démarré dure zéro
seconde, et c'est exactement celle qu'on ira chercher dans l'historique.

Le `has_error` qui décide de cela est lu des lignes par le serveur, jamais reçu du client : un
client n'a pas à pouvoir épingler une séance dans l'historique en le déclarant.

## Ce que cet ADR ne résout pas

Il ne dit pas pourquoi la lecture échouait sur Android. Il rend la panne visible et la répare dans
le seul cas qu'il sait réparer, celui du conteneur refusé. La cause réelle se lira dans le premier
journal remonté.

Le journal reste réservé à qui administre le serveur (`manage_users`), comme l'historique qui le
porte. Un utilisateur ne peut pas relire le journal de ses propres lectures passées ailleurs que
sur l'appareil qui les a faites.

## À vérifier

- `go build ./...` et `go test ./...` sur `server/` : le code Go de cet ADR n'a jamais été compilé.
- Que la migration 10 s'applique sur une base existante, et que `ON DELETE CASCADE` emporte bien les
  journaux quand l'historique est vidé (`PRAGMA foreign_keys=ON` est posé, mais non vérifié ici).
- Qu'une lecture qui échoue au démarrage laisse bien une ligne d'historique, avec son journal.
