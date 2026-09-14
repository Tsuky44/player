# Progression entre serveurs

Voir [ADR-0017](adr/0017-serveurs-lies-et-progression-entre-serveurs.md).

## Lier ses comptes

Dans **Serveurs → menu du compte → Lier un compte**, la personne choisit un autre de
ses comptes, sur un autre serveur. Les noms d'utilisateur peuvent être différents.
Juste après avoir ajouté un serveur avec un mot de passe, l'app propose aussi de le
lier au compte actif ; rien n'est lié sans le demander.

Le lien est enregistré **sur les deux serveurs**, pas sur l'appareil : un autre
appareil connecté à l'un des deux comptes voit l'autre serveur dans **Vos autres
serveurs** et s'y connecte en tapant son mot de passe une fois.

**Dissocier ce compte** arrête les échanges ; l'historique déjà partagé reste sur
chaque serveur.

## Accord des administrateurs

La première fois que deux serveurs sont liés, un administrateur de chaque serveur
(droit « gérer les paramètres ») doit l'autoriser dans **Paramètres → Serveurs liés**.
Tant que ce n'est pas fait, le lien est affiché « en attente des administrateurs ».
L'accord vaut pour la paire : les comptes liés ensuite entre ces deux mêmes serveurs
sont actifs immédiatement. Retirer un serveur lié dissocie tous les comptes qui en
dépendent.

Les deux serveurs doivent pouvoir se joindre. Si l'adresse transmise par l'appareil
n'est pas joignable depuis l'autre serveur, l'administrateur la corrige avec
**Modifier l'adresse** ; la dernière erreur de transmission est affichée sous le serveur.

## Transmission

Chaque modification de progression — lecture, vu/non vu, rejeu d'une lecture hors
ligne, progression reçue d'un autre serveur — est notée par le serveur et transmise
en arrière-plan aux serveurs liés, en quelques secondes, sans qu'aucune app n'ait
besoin d'être ouverte. Un serveur injoignable reçoit tout à son retour. Le premier
lien transmet l'historique existant.

Un film est reconnu par son identifiant TMDB ; un épisode par l'identifiant TMDB de
sa série, son numéro de saison et son numéro d'épisode. Un média sans cette identité
reste propre à son serveur. Les titres et les numéros de fichiers locaux ne servent
jamais à associer deux contenus. La date du visionnage est conservée : un historique
ancien ne remplace pas une lecture plus récente, et à date identique chaque serveur
garde son état. Les épisodes terminés alimentent le calcul existant du prochain
épisode à reprendre.

Pour utiliser cette fonction, mettre à jour l'app et les serveurs concernés.

## Relais de lecture

Pendant la lecture en ligne, le lecteur vérifie toutes les dix secondes si sa source
reste joignable. Si elle ne répond plus, il cherche le même contenu sur les autres
comptes du groupe. La source doit être indisponible : une pause ou une erreur de
codec seule ne déclenche pas de changement de serveur.

`GET /api/media-identities` permet à l'app de mémoriser l'identité des contenus avant
une panne. `POST /api/media-resolve` retrouve une copie exacte sur le serveur de secours
et vérifie que son fichier est lisible. Une identité d'épisode jamais mise en cache
ne peut pas être devinée depuis son titre lorsque la source est hors ligne.

Le lecteur rouvre le contenu au dernier instant connu, conserve les préférences de
lecture et l'état de pause, et indique le serveur choisi. Le compte actif change aussi,
pour que la navigation vers les épisodes suivants utilise la bibliothèque disponible.
Le client du lecteur précédent reste attaché à sa source pendant la fermeture : ni ses
requêtes tardives ni ses identifiants locaux ne sont redirigés vers le nouveau compte.
Une source quittée est écartée pendant trente secondes pour éviter les allers-retours
en cas de panne intermittente. Une lecture téléchargée localement reste locale.

Le relais utilise les liens déclarés par les serveurs, dont l'app garde une copie pour
les retrouver quand un serveur ne répond plus. Il suppose que l'appareil ait une
session sur le serveur de secours ; aucun mot de passe ne passe d'un serveur à l'autre. Le relais est automatique avec une interruption de
réouverture du flux, pas une commutation vidéo sans coupure.
