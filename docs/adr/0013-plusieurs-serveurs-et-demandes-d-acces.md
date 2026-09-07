# ADR-0013 — Plusieurs serveurs dans l'app, et la demande d'accès

- **Statut :** accepté
- **Date :** 2026-09-07
- **Portée :** app cliente (carnet de comptes, bascule) et serveur (demandes d'accès).
  Aucune fédération entre serveurs : ils continuent de s'ignorer.

## Contexte

L'app tenait **une** adresse (`server_url`) et **un** jeton (`auth_token`). Changer de serveur
voulait donc dire écraser les deux — c'est-à-dire se déconnecter du premier, et devoir retaper un
mot de passe pour y revenir. Une personne qui a un serveur chez elle et un compte chez un proche
n'avait pas d'autre choix que de faire l'aller-retour à la main, à chaque fois.

Et pour obtenir ce compte chez le proche, il n'existait qu'un chemin : l'**invitation** (ADR-0001).
Elle part de l'administrateur, transite par un canal extérieur à l'app — message, mail — et suppose
que celui qui invite y pense en premier. Le mouvement inverse, « je vois ton serveur, laisse-moi
entrer », n'existait pas.

## Décision

### Un compte par serveur, et l'app en tient plusieurs

Il n'y a pas d'identité fédérée et il n'en est pas créé une. Chaque serveur garde sa table `users`,
son numérotage, ses droits ; « mon compte » veut dire une identité **par** serveur. Ce que l'app
ajoute, c'est un carnet ([`ServerRegistry`](../../app/lib/services/server_registry.dart)) : la liste
des serveurs auxquels **cet appareil** a un compte, un jeton rangé par compte, et un pointeur sur
celui qui est actif.

Basculer ne renégocie donc rien. Le jeton de l'autre serveur était déjà là, il n'avait simplement
pas cours ; changer de serveur, c'est déplacer le pointeur. C'est pour cela qu'on revient sur
l'autre serveur sans rien retaper.

L'alternative — un compte unique reconnu par plusieurs serveurs — supposait un émetteur d'identité
commun, donc un service central dans un projet dont c'est exactement l'inverse du propos : chaque
serveur est autonome et n'a besoin de personne.

**Le jeton du serveur actif n'est jamais présenté à un autre.** Les appels qui visent un serveur
tiers (demande d'accès, ajout d'un serveur avec un mot de passe) partent sur un client Dio nu, sans
l'intercepteur qui pose l'en-tête `Authorization` : envoyer à B la session ouverte chez A serait la
lui confier.

### Ce qui est en mémoire appartient au serveur qu'on quitte

Un `media_id` est un numéro propre à un serveur : le film 42 de l'un n'a rien à voir avec le film 42
de l'autre. À la bascule, l'accueil, la bibliothèque et le catalogue de demandes sont donc vidés
avant que le nouveau serveur réponde — sinon l'ancienne bibliothèque resterait affichée le temps du
premier chargement, avec des affiches pointant vers une adresse qui n'est plus la bonne.

Les **téléchargements** posaient le même problème en pire, parce qu'ils survivent au processus : le
manifeste est indexé sur `media_id`, et deux serveurs auraient fini par se recouvrir à la première
collision de numéro. Le manifeste continue de tout porter — les fichiers sont sur le disque, ils
n'ont pas à disparaître — mais la carte en mémoire ne contient que le serveur actif, et ce qui
appartient aux autres est réécrit intact. On retrouve ses téléchargements en revenant sur leur
serveur, pas ailleurs.

Le câblage de cette remise à zéro est dans `main()`, pas dans `AuthProvider` : savoir qui est
connecté n'oblige pas à connaître la bibliothèque ni les téléchargements.

### La demande d'accès est l'invitation à l'envers

L'invitation est **poussée** : un administrateur fabrique un lien et le fait parvenir. La demande
d'accès est **tirée** : quelqu'un sonne, un administrateur ouvre ou non. La forme reprend celle de
l'appairage TV (ADR-0003) : demander → interroger → décider.

- `POST /api/auth/access/request` — non authentifiée, parce que le demandeur n'a précisément pas de
  compte ici. Elle **ne crée rien** : une ligne en attente, portant le hash bcrypt du mot de passe
  proposé, et un code aléatoire de 256 bits rendu au demandeur.
- `POST /api/auth/access/poll` — le verdict, et la session une seule fois. Sûre pour la même raison
  que l'appairage TV : le code est un secret que seul l'appareil demandeur détient.
- `GET /api/access-requests`, `POST /api/access-requests/:id/{approve,deny}` — le côté décideur.

**Le mot de passe est proposé au moment de la demande, pas à l'approbation.** L'alternative — la
demande sans mot de passe, puis un jeton d'invitation à relever — obligeait soit à garder le mot de
passe en clair sur l'appareil pendant des jours, soit à faire retaper un formulaire à quelqu'un qui
a déjà rempli le sien la semaine précédente. Une ligne en attente porte donc un hachage bcrypt,
exactement comme le ferait la table `users`, et un refus efface ce hachage avec la décision.

**L'approbation crée le compte et la session dans la même transaction.** Un compte sans session
laisserait le demandeur devant un mot de passe qu'il croit refusé ; une décision sans compte le
ferait attendre indéfiniment.

### Approuver n'accorde pas plus que ce qu'on peut déjà accorder

La règle d'ADR-0001 est reprise telle quelle : un titulaire de `manage_users` choisit librement les
droits — il peut promouvoir après coup de toute façon — tandis qu'un simple `invite_users` accorde
**son gabarit** (`invite_grants`), quoi qu'il envoie dans la requête. Sans cela, « accepter une
demande » serait le chemin détourné par lequel un inviteur se fabrique un administrateur, et le
droit d'inviter redeviendrait le droit de tout faire.

`invite_users` suffit donc à ouvrir la porte : accepter quelqu'un est exactement ce que fait déjà
un lien d'invitation.

### Les garde-fous d'une route ouverte

`request/poll` sont accessibles sans compte, ce qui impose un fond :

- **Serveur vierge : refusé.** Personne ne peut décider, la demande resterait en attente jusqu'à son
  expiration. C'est l'inscription du propriétaire qu'il faut faire d'abord.
- **Identifiant déjà pris : refusé tout de suite**, plutôt que de faire attendre une semaine pour un
  conflit connu d'avance. La question est retranchée une seconde fois à l'approbation, où elle se
  décide pour de bon — une semaine a pu passer.
- **Doublon sur le même identifiant : refusé.** C'est la même personne qui insiste, pas une nouvelle
  demande.
- **Cinquante demandes en attente au maximum**, sinon n'importe qui pourrait noyer l'écran de
  l'administrateur.
- **Sept jours**, comme l'invitation : celui qui décide peut très bien ne rouvrir l'app que le
  week-end. L'expiration est dérivée à la lecture ; le balayeur ne fait que récupérer des lignes, et
  au passage les sessions approuvées que personne n'est venu relever.

### Ce que l'app fait de la réponse

Une demande en attente est notée **sur l'appareil**, pas seulement à l'écran : la réponse peut
prendre des jours, et le code qui permettra de relever la session ne se retrouve nulle part ailleurs.
Elle est réinterrogée au démarrage, au retour du réseau, et pendant que l'écran des serveurs est
ouvert.

Une approbation qui arrive alors qu'une session est déjà ouverte **n'arrache pas l'écran** : le
compte entre au carnet, et c'est l'utilisateur qui bascule quand il veut — il regardait peut-être un
film. Sur un appareil qui n'a encore aucun compte, elle ouvre la session, parce que c'est
précisément ce qu'il attendait.

### Se déconnecter d'un serveur n'est pas se déconnecter de l'app

Quand un autre compte reste au carnet, la déconnexion y bascule au lieu de retomber sur l'écran de
connexion. Retirer un serveur du carnet ne ferme pas sa session côté serveur : on ne peut pas la
fermer sans repointer le client dessus, et un compte retiré de cet appareil-ci n'a pas à faire
tomber les autres.

## Conséquences

- **Migration silencieuse.** `server_url` + `auth_token` + `cached_profile` deviennent le premier
  compte du carnet au premier lancement ; les anciennes clés sont ensuite effacées, parce qu'un jeton
  que plus personne ne lit est un identifiant qui traîne. Sans cette reprise, la mise à jour
  déconnecterait tout le monde.
- **Un profil en cache par compte**, sinon la session hors ligne rouvrirait l'identité du dernier
  serveur connecté plutôt que celle du serveur actif.
- **Changer l'adresse du serveur dans les réglages déplace le compte** au lieu de repointer le
  client : le même serveur se joint parfois autrement — l'IP locale hier, un nom de domaine
  aujourd'hui —, et le jeton reste valable, c'est le serveur qui le connaît, pas l'adresse.
- Le sélecteur de serveur n'apparaît dans le menu de compte qu'à partir de deux serveurs. Un seul
  serveur n'a pas besoin d'un menu pour en changer.
- **Les téléchargements suivent le serveur actif** (voir plus haut). C'est un changement de
  comportement visible sur un appareil qui aurait des médias venant de deux serveurs.
- Un transfert en cours est coupé net à la bascule et redevient une entrée de file : il tire sur une
  adresse dont on vient de changer, et il repartira à l'octet près au retour.
- **`/stream` reste public** (ADR-0001) : rien ici ne referme cet accès, et un média téléchargé
  depuis un serveur reste lisible hors ligne quel que soit le serveur actif.
- L'écran de connexion doit être recompilé pour le build web (`server/webui/dist`) pour que la
  demande d'accès fonctionne dans le navigateur — même remarque qu'ADR-0001 pour l'inscription
  par lien.
