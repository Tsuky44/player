# ADR-0040 — Un téléchargement continue écran verrouillé

- **Statut :** accepté, en cours. Le Dart est analysé et testé, le serveur vérifié par `go vet`.
  **Le Swift n'a été compilé sur aucun Mac**, et le service Android n'a pas encore tourné sur un
  appareil.
- **Date :** 2026-09-30
- **Portée :** l'app sur Android et iPhone (`packages/onyx_background_downloads`,
  `app/lib/services/downloads/`), et la création des tickets de lecture côté serveur
  (`server/playbackauth`). macOS, Windows et le web ne changent pas ; l'Apple TV ne télécharge pas.
- **Prolonge :** [ADR-0010](0010-telechargements-hors-ligne.md) et
  [ADR-0027](0027-reserve-de-telechargements-et-reseau-facture.md), qui laissaient tous deux « un
  service d'arrière-plan Android à faire ».

## Contexte

Le transfert d'un média est un `GET Range:` écrit en append par le Dart (ADR-0010 §1). Il ne vit
donc que tant que le processus de l'app tourne. Or le geste courant est justement de lancer une
saison, puis de verrouiller le téléphone :

- **Android** gèle une app sans service de premier plan quelques minutes après l'extinction de
  l'écran, puis la sort du réseau quand l'appareil passe en Doze. Le transfert s'arrête, et ne
  repart qu'à la réouverture.
- **iOS** suspend l'app dès qu'elle passe en arrière-plan. Aucun code Dart ne tourne plus : ni le
  transfert, ni le renouvellement du ticket de lecture.

Le ticket, justement : `/stream` est protégé par un ticket de lecture de 15 minutes, que le client
renouvelle toutes les 5 minutes et que `GuardWriter` vérifie **à chaque écriture**. Une réponse en
cours est coupée au bloc suivant quand il expire. Même en confiant les octets au système, un
téléchargement iOS serait coupé au bout d'un quart d'heure.

## Décision

### 1. Android : un service de premier plan qui suit la file

Le transfert reste le même, dans le même processus ; il suffit que ce processus continue de tourner.
Un service de premier plan de type `dataSync` le garde vivant, l'exempte des coupures réseau de Doze,
et tient un verrou processeur et un verrou Wi-Fi (le mode que prend ExoPlayer en lecture).

Le service suit `DownloadManager.isTransferring` — la file tourne, **entre deux médias compris**. Ce
détail compte : Android refuse de démarrer un service de premier plan depuis l'arrière-plan. Un
service arrêté entre deux épisodes, écran éteint, ne repartirait pas pour le suivant. À l'inverse,
une file à l'arrêt (réseau refusé par le réglage de l'ADR-0027, serveur perdu) ne garde rien
éveillé : elle attend un événement, pas un processeur.

La notification, qu'Android exige, dit ce qui descend : la série, l'épisode, les octets, ce qui
attend. La permission des notifications est demandée au premier téléchargement (Android 13+) ;
refusée, le service tourne quand même. Android 15 borne ce type de service à six heures par jour :
au-delà, le service s'arrête et le transfert continue tant que le système laisse vivre le processus.

### 2. iPhone : une session URLSession d'arrière-plan, en tranches

Sur iOS, seul le système peut télécharger pendant que l'app est suspendue : une session
`URLSessionConfiguration.background`, dont les octets arrivent dans un processus à lui.

Le fichier n'y part pas en une tâche mais en **tranches de 256 Mo**, toutes confiées d'un coup.
Deux raisons :

- **une tâche coupée ne rend ses octets que par `resumeData`**, qui rejoue l'URL d'origine — donc
  son ticket, révoqué à la pause ou expiré depuis. Une tranche finie, elle, est sur le disque et y
  reste ; une coupure ne coûte que les tranches en vol ;
- **une tâche créée en arrière-plan est discrétionnaire** : iOS la lance quand bon lui semble,
  souvent pas avant le prochain branchement au secteur. Créées toutes au premier plan, les tranches
  d'un film partent tout de suite, écran verrouillé ou non.

Le natif est volontairement mince : confier une tranche, dire lesquelles courent, annuler. Une
tranche finie est déposée à côté du fichier (`video.mkv.part-<début>`) si le serveur a bien servi la
plage demandée. Assembler, compter, réessayer se fait en Dart (`BackgroundMediaTransfer`), où c'est
testé. L'assemblage ne dépend de rien d'autre que la taille du fichier : une app tuée au milieu
reprend à l'octet manquant, et le fichier reste un préfixe exact de celui du serveur — la reprise
de l'ADR-0010 §1 est inchangée.

Une tranche qui revient trois fois sans ses octets fait échouer le média, avec la raison donnée par
le système (`HTTP 401`, par exemple). Un serveur qui ignore `Range:` est servi d'un bloc, par le
transfert habituel.

### 3. Un ticket « téléchargement » de six heures

`POST /api/playback/tickets` accepte `"purpose": "download"`, qui délivre un ticket d'échéance
`DownloadTTL` (6 h) au lieu de 15 minutes, et dont le renouvellement redonne six heures. C'est le
même ticket en tout le reste : un seul média, un seul compte, le même plafond par compte, révocable,
et toujours vérifié à chaque écriture par `GuardWriter`. Le client ne le demande que pour un
téléchargement, sur toutes les plateformes.

Un serveur plus ancien ignore le champ et délivre un ticket de lecture : le téléchargement iOS est
alors coupé au bout d'un quart d'heure écran verrouillé, et repart à la réouverture. Rien ne casse.

## Conséquences

- Le risque accepté : un ticket de téléchargement fuité ouvre un média pendant six heures au lieu de
  quinze minutes. Il reste lié à ce média et à ce compte, n'apparaît que dans l'URL de `/stream`, et
  la révocation l'arrête au bloc suivant.
- iOS : seul le média en cours part écran verrouillé sans délai. Le suivant de la file est confié
  quand l'app se réveille — iOS la réveille brièvement à la fin de chaque lot de tranches — mais ses
  tâches, créées en arrière-plan, sont discrétionnaires. Une saison lancée puis verrouillée descend
  donc vite pour le premier épisode, et au rythme d'iOS pour les suivants (en pratique : sur secteur
  et en Wi-Fi). Confier toute la file d'avance demanderait un ticket par épisode, créé au premier
  plan et valable jusqu'à son tour ; c'est la piste si l'usage le réclame.
- iOS : les tranches sont assemblées quand le Dart tourne. Un film arrivé écran verrouillé peut donc
  apparaître « en cours » jusqu'à la réouverture, le temps de recopier ses tranches (quelques
  secondes par gigaoctet).
- iOS : l'arbitrage du réseau facturé (ADR-0027 §7) reste posé entre deux médias. Les tranches d'un
  média déjà confié continuent en 4G si le Wi-Fi tombe, comme le faisait déjà un transfert en cours.
- Android : une réserve qui se remplit alors que l'app est déjà en arrière-plan (retour du Wi-Fi
  écran éteint) ne peut pas démarrer le service ; elle télécharge tant que le processus vit, comme
  avant.
- Le transfert est sorti de `download_manager_io.dart` derrière `MediaTransfer` : le magasin décide
  quoi et quand, un transfert ne sait que remplir un fichier.
