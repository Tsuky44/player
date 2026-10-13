# ADR-0059 — Notifications de nouveaux épisodes : l'appareil interroge ses serveurs

- **Statut :** accepté, en cours. Le Dart est analysé et testé, et l'app Android se construit.
  **Aucune notification n'a encore été vue arriver sur un appareil**, et le Swift de
  l'`AppDelegate` n'a été compilé sur aucun Mac.
- **Date :** 2026-10-12
- **Portée :** l'app sur Android et iPhone/iPad — `app/lib/services/new_episodes/`,
  `app/lib/services/api/new_episodes.dart`, `app/lib/navigation/new_episode_opener.dart`,
  `app/lib/screens/settings/widgets/new_episode_alerts_group.dart`,
  `app/ios/Runner/AppDelegate.swift`, `app/ios/Runner/Info.plist`,
  `app/android/app/build.gradle.kts`. Le serveur ne change pas. Téléviseurs, ordinateurs et web
  ne sont pas concernés.
- **Prolonge :** [ADR-0013](0013-plusieurs-serveurs-et-demandes-d-acces.md) (plusieurs serveurs,
  aucun service central) et [ADR-0057](0057-attendre-sa-langue.md) (ce que « nouvel épisode »
  veut dire).

## Contexte

Le serveur sait déjà dire qu'un épisode vient de sortir pour une série qu'on suit : c'est le
drapeau `has_new_episode` des entrées de « À reprendre » (`isNewEpisodeRelease`, et l'arrivée de
la langue attendue de l'ADR-0057). L'app en fait une pastille sur l'accueil.

Mais il faut ouvrir l'app pour la voir, et l'ouvrir **sur le bon serveur** : quelqu'un qui a un
compte chez lui et un autre chez un proche devait basculer de l'un à l'autre pour savoir si
quelque chose était sorti. C'est exactement le geste qu'une notification remplace.

## Décision

### 1. Pas de push : l'appareil va demander

Une notification poussée (FCM, APNs) suppose quelqu'un qui pousse. Les clés APNs et FCM sont
celles de l'éditeur de l'app : un serveur auto-hébergé ne peut pas les détenir, et les lui confier
reviendrait à les publier. Il faudrait donc un relais central par lequel passeraient tous les
serveurs — ce que l'ADR-0013 écarte : chaque serveur est autonome et n'a besoin de personne.

L'appareil interroge donc lui-même, de temps en temps, **chacun des comptes de son carnet**
(`ServerRegistry`), et affiche une notification **locale**. Le prix est un délai : la notification
n'arrive pas à la seconde où le fichier est indexé, mais au passage suivant.

- **Android** : une tâche périodique WorkManager, toutes les heures, quand il y a du réseau.
- **iPhone** : une `BGAppRefreshTask`, dont une heure n'est que le plancher. iOS choisit l'heure
  selon l'usage qu'on fait de l'app, et peut ne pas la lancer du tout (économie d'énergie, app
  balayée du sélecteur). L'app ouverte fait donc le même tour — au lancement, au retour au premier
  plan, au retour du serveur — pour rattraper ce qu'iOS n'a pas fait.

Un serveur local injoignable depuis la 4G ne répond pas : rien n'est appris de lui, et il annonce
au passage suivant où il répond.

### 2. Le serveur décide de ce qui est nouveau, l'appareil retient ce qu'il a dit

`NewEpisodeWatch` ne recalcule rien : il lit `continue_watching` de `GET /api/home` et ne garde
que les entrées `has_new_episode`. Aucune route n'est ajoutée, donc **tous les serveurs déjà
déployés sont couverts**, y compris ceux d'un proche qui ne met pas à jour.

Ce que l'appareil ajoute, c'est une mémoire (`NewEpisodeLedger`, dans les préférences) : par
compte, les épisodes déjà annoncés, sous la clé `série:saison×épisode`. Le numéro plutôt que
l'identifiant du fichier — un épisode remplacé par une meilleure copie change d'identifiant et ne
mérite pas une seconde notification.

Trois règles en découlent :

- **Le premier regard sur un compte est un état des lieux.** Ce qui est déjà marqué nouveau est
  enregistré sans être annoncé ; sinon activer la fonction annoncerait d'un coup tout ce que
  l'accueil affiche depuis des jours.
- **Le serveur à l'écran n'annonce rien** quand c'est l'app ouverte qui fait le tour : sa pastille
  le dit déjà. Les autres serveurs, eux, sont précisément ceux qu'on ne regarde pas.
- **Un compte retiré de l'appareil emporte sa mémoire.**

### 3. La logique est en Dart, le natif ne fait que réveiller

Comme pour les téléchargements (ADR-0040), le natif est mince. `workmanager` réveille un point
d'entrée Dart (`newEpisodeBackgroundEntry`) dans un moteur sans interface, et
`flutter_local_notifications` affiche. Tout le reste — le tour des serveurs, la mémoire, le texte
— est du Dart testé sans appareil.

La requête de fond part sur le client nu d'un compte (`ApiClient.continueWatchingOf`), avec son
jeton à lui et **sans les en-têtes `X-Onyx-Device` / `X-Onyx-Client`** : le moteur de fond n'a pas
accès au canal qui donne le nom de l'appareil, et en envoyer un autre renommerait la session dans
la liste des appareils connectés.

### 4. Toucher la notification ouvre la série, sur son serveur

La charge de la notification porte le compte et l'identifiant de la série. `NewEpisodeOpener`
attend que la session soit ouverte, bascule sur le serveur visé s'il n'est pas l'actif — un
identifiant de série ne veut rien dire ailleurs — puis ouvre la fiche.

### 5. Activé par défaut, sur téléphone et tablette seulement

Le réglage vit dans *Réglages → Cet appareil → Notifications*, et il est allumé tant que personne
n'y touche : c'est ce qu'on attend d'une app qui suit des séries. La permission du système est
demandée une fois, à la première session ouverte. Un téléviseur n'a pas de volet où lire une
notification, et un ordinateur n'a pas de tâche de fond app fermée : le réglage n'y apparaît pas.

## Conséquences

- **`GET /api/home` est plus lourd que nécessaire** pour cette question : il calcule aussi les
  rangées de l'accueil. Une requête par compte et par heure reste négligeable ; une route dédiée,
  annoncée par une capacité de `/api/ping`, est la suite logique si le coût se voit. Elle ne
  dispenserait pas du repli sur `/api/home` pour les serveurs anciens.
- **Seuls les dix premiers de « À reprendre » sont vus.** Les nouveautés y sont triées en tête
  (`buildContinueWatching`), donc il faudrait plus de dix sorties le même jour pour en perdre une.
- **Le serveur voit l'appareil actif** à chaque passage (`lastSeen` de la session).
- **Deux dépendances de plus.** `flutter_local_notifications` exige le désucrage Java sur Android
  et compile, sans être appelé, sur Windows, macOS, Linux et le web. `workmanager` déclare les
  permissions `FOREGROUND_SERVICE` et `FOREGROUND_SERVICE_SHORT_SERVICE`, dont l'app ne se sert
  pas. Aucun des deux ne déclare tvOS.
- **L'icône de la barre d'état** (`ic_stat_onyx`) n'est nommée que depuis le Dart :
  `res/raw/keep.xml` la protège du réducteur de ressources.
- **Ce que le natif exige ne casse aucun build quand ça manque** — l'identifiant de la tâche dans
  l'`Info.plist` et l'`AppDelegate`, l'icône, le désucrage. La notification n'arriverait
  simplement jamais : `test/new_episode_alerts_wiring_test.dart` relit ces fichiers.
- **iOS : `Podfile.lock` est à régénérer** (`pod install`) sur un Mac, pour les deux nouveaux pods.
- **Sur Android, certains constructeurs** (Xiaomi, Huawei, Samsung en économie d'énergie) tuent
  les tâches de fond d'une app peu utilisée. La notification y arrive alors à la prochaine
  ouverture de l'app, par le tour qu'elle fait elle-même.
