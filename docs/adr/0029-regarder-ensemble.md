# ADR-0029 — Regarder ensemble : une séance partagée, synchronisée par long-polling

- **Statut :** accepté, réalisé — pas encore essayé à deux appareils sur un vrai serveur
- **Date :** 2026-09-23
- **Portée :** le serveur (`server/handlers/watch_party.go`, cinq routes `/api/watch-parties`) et le
  lecteur (`app/lib/services/watch_party.dart`, `player_screen.dart`, le menu du compte)

## Contexte

On voulait l'équivalent du « Watch Together » de Plex : plusieurs personnes regardent le même
film, chacune sur son appareil et pas forcément avec le même compte. Les commandes sont
partagées : si l'une met en pause, tout le monde est en pause.

La feuille de route ([roadmap-parite-plex-emby](../roadmap-parite-plex-emby.md)) le rangeait parmi
les sujets moins prioritaires. On l'a quand même avancé, sur demande.

## Décision

### 1. Une séance vit sur un serveur, en mémoire

L'hôte ouvre une séance depuis le lecteur. Le serveur lui donne un code de six caractères, tiré du
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

### 3. Aucune horloge partagée

Le serveur envoie la position **extrapolée au moment de sa réponse**. L'appareil y ajoute le temps
écoulé depuis la réception, mesuré par un chronomètre local. On ne compare jamais l'heure du
serveur à celle de l'appareil. L'erreur se limite à la moitié du temps d'aller-retour, bien en
dessous de la tolérance.

### 4. Les gestes partent, les recalages ne repartent pas

Le lecteur n'envoie que les gestes de la personne devant l'écran : `_togglePlayPause` et `_seekTo`,
par lesquels passent désormais toutes les recherches voulues. Ce qui vient de la séance
s'applique par `_WatchPartyBinding`, directement sur le contrôleur, et ne repart jamais. C'est ce
qui empêche l'écho.

Tant qu'un geste local n'est pas confirmé, la séance connue localement est en retard sur l'écran.
Aucun recalage n'a donc lieu pendant ce temps : sinon il annulerait la pause qu'on vient de
demander.

Tolérances : 1,2 s après un geste explicite (tout le monde sur la même image), 2,5 s en lecture
continue, avec au plus une correction toutes les 6 s. Une recherche peut reconstruire une session
HLS, et chercher en boucle serait pire qu'un léger décalage.

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
- **Pas d'attente collective en cas de chargement.** Un appareil dont le tampon se vide prend du
  retard, puis le recalage le ramène sur la séance. Les autres ne s'arrêtent pas pour l'attendre.
- **Télécommande.** La pastille « Regarder ensemble » est un bouton superposé à tous les
  habillages. Elle n'est pas dans le parcours du focus de la barre de commandes TV. Sur un
  téléviseur, on peut rejoindre une séance, mais pas en démarrer une.
- La vitesse de lecture n'est pas partagée.
- Pas encore essayé de bout en bout. Le serveur n'a pas été compilé sur la machine de
  développement (pas de Go installé en local). À vérifier avec `go test ./handlers/` et un essai à
  deux appareils.
