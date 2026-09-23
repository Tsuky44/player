# ADR-0029 — Regarder ensemble : une séance partagée, synchronisée par long-polling

- **Statut :** accepté, réalisé — pas encore essayé à deux appareils sur un vrai serveur
- **Date :** 2026-09-23
- **Portée :** le serveur (`server/handlers/watch_party.go`, cinq routes `/api/watch-parties`) et le
  lecteur (`app/lib/services/watch_party.dart`, `player_screen.dart`, le menu du compte)

## Contexte

On voulait pouvoir regarder ensemble : plusieurs personnes regardent le même
film, chacune sur son appareil et pas forcément avec le même compte. Les commandes sont
partagées : si l'une met en pause, tout le monde est en pause.

La feuille de route ([roadmap-lecture](../roadmap-lecture.md)) le rangeait parmi
les sujets moins prioritaires. On l'a quand même avancé, sur demande.

## Décision

### 1. Une séance vit sur un serveur, en mémoire

L'hôte ouvre une séance depuis le bouton « Regarder ensemble » de la barre du lecteur (dans
chaque habillage ; dans une disposition Studio qui ne le place pas, un bouton discret en bas à
droite). Le serveur lui donne un code de six caractères, tiré du
même alphabet que les codes d'appairage (sans 0/O ni 1/I). Les autres entrent ce code via
*menu du compte › Rejoindre une séance*, **sur le même serveur**, avec leur propre compte. Le
catalogue est partagé entre tous les comptes ([ADR-0001](0001-user-permissions-and-invitations.md)),
donc tout le monde peut lire le média.

Le serveur ne garde qu'un état de référence par séance : le média, lecture ou pause, et la position
à un instant donné. Chaque changement incrémente un numéro de version. Rien n'est écrit en base. Une
séance n'a de sens que tant que ses participants sont là, et un redémarrage du serveur couperait de
toute façon leurs flux.

### 2. Long-polling, pas de WebSocket

Chaque appareil attend le prochain changement avec `GET /api/watch-parties/:code?since=N`. La
requête répond dès que la version dépasse N, ou au bout de 20 s. Cette attente sert aussi de signe
de vie : un participant muet depuis 50 s est retiré.

Pourquoi pas de WebSocket : le long-polling passe par le client Dio existant, avec son jeton, sur
toutes les plateformes (web et Apple TV compris). Il n'ajoute de dépendance ni côté Go ni côté
Flutter. Il traverse aussi le middleware gzip et les proxys sans réglage. Le coût est une requête
toutes les 20 s par participant quand rien ne bouge, ce qui est négligeable.

### 3. Aucune horloge partagée, mais la latence mesurée

Le serveur envoie la position **extrapolée au moment de sa réponse**. L'appareil y ajoute le temps
écoulé depuis cet instant, mesuré par un chronomètre local. On ne compare jamais l'heure du
serveur à celle de l'appareil. Le trajet retour est compensé : l'appareil mesure l'aller-retour
(un poll sur une version dépassée répond sur-le-champ, toutes les 15 s, plus chaque geste) et
retient la moitié du plus court des six derniers.

### 4. Les gestes partent, les recalages ne repartent pas

Le lecteur n'envoie que les gestes de la personne devant l'écran : `_togglePlayPause` et `_seekTo`,
par lesquels passent désormais toutes les recherches voulues. Ce qui vient de la séance
s'applique par `_WatchPartyBinding`, directement sur le contrôleur, et ne repart jamais. C'est ce
qui empêche l'écho.

Tant qu'un geste local n'est pas confirmé, la séance connue localement est en retard sur l'écran.
Aucun recalage n'a donc lieu pendant ce temps : sinon il annulerait la pause qu'on vient de
demander.

Le recalage se fait en deux temps, évalués deux fois par seconde :

- **En lecture, par la vitesse.** Au-delà de 80 ms d'écart, la vitesse varie de 20 % par seconde
  d'écart, plafonnée à ±8 %, jusqu'à revenir sous 30 ms. Rien ne se coupe, et la correction
  audio de hauteur (mpv, ExoPlayer, navigateur) la rend inaudible. Au-delà de 1,5 s, on cherche,
  à la milliseconde près (`seekToAbsolutePosition`).
- **À l'arrêt, par une recherche.** Tout le monde sur la même image à 0,2 s près : chercher en
  pause ne se voit pas.

### 4 bis. Quand un appareil charge, tout le monde l'attend

Un lecteur qui charge (première image pas encore là, tampon vide depuis plus de 400 ms,
reconstruction de session) envoie `loading`. Le serveur le marque *attendu* et **fige la
séance** pour tout le monde, à la position où cet appareil s'est arrêté (au plus 15 s en
arrière). Il ne rate donc rien. Les autres se mettent en pause et reculent d'autant. Le lecteur
attendu, lui, ne se met pas en pause : il continue de remplir son tampon. Une fois prêt, il se
tient à l'arrêt et envoie `loading: false`. Le serveur relance alors tout le monde d'un même
changement de version. Le message « En attente de alex… » s'affiche pendant l'attente.

Le serveur attend aussi le nouveau venu jusqu'à sa première image, et tout le monde quand la
séance passe à un autre épisode : on part ensemble.

Au bout de 20 s, le serveur cesse d'attendre un appareil qui charge encore. Cet appareil ne
redemande pas d'attente pour ce même chargement : il rattrapera seul, plutôt que de bloquer la
séance en boucle.

### 5. L'épisode suivant emmène tout le monde

Passer à un autre épisode (à la main ou en enchaînement automatique) envoie `media`. Les autres
lecteurs ouvrent l'épisode à leur tour. Tant que le serveur n'a pas confirmé, le lecteur du nouvel
épisode ignore la séance, qui annonce encore l'ancien.

Quitter le lecteur, c'est quitter la séance. Si l'hôte part, le plus ancien participant restant
prend sa place, et une séance vide disparaît. La bascule automatique vers un serveur lié
([ADR-0017](0017-serveurs-lies-et-progression-entre-serveurs.md)) est désactivée pendant une
séance : elle couperait l'appareil des autres.

## Conséquences

- **Même serveur seulement.** Des amis sur deux serveurs Onyx différents ne peuvent pas encore
  regarder ensemble. Il faudrait relayer la séance par la fédération et faire correspondre les
  médias par leur identité ([ADR-0002](0002-identification-des-medias.md)).
- **Vitesse de lecture.** Elle n'est pas partagée. Une personne qui passe en ×1,25 pendant une
  séance sera ramenée en arrière par des recherches répétées.
- **Latence audio propre à l'appareil** (casque Bluetooth, barre de son) : elle n'est pas
  mesurable ici, et reste comme écart résiduel.
- Pas encore essayé de bout en bout. Le serveur n'a pas été compilé sur la machine de
  développement (pas de Go installé en local). À vérifier avec `go test ./handlers/` et un essai à
  deux appareils.
