# Progression entre serveurs

Dans **Serveurs → menu du compte → Lier un compte**, la personne choisit les comptes
qui lui appartiennent. Leurs noms d'utilisateur peuvent être différents. L'app
synchronise uniquement les comptes explicitement liés sur cet appareil, en groupes
séparés. Les liaisons survivent au redémarrage et au changement d'adresse d'un serveur.
**Dissocier ce compte** arrête les échanges futurs ; l'historique déjà partagé reste
sur chaque serveur. Les comptes existants ne sont pas liés automatiquement.
Un film est reconnu par son identifiant TMDB ; un épisode par l'identifiant TMDB de
sa série, son numéro de saison et son numéro d'épisode. Un média sans cette identité
reste propre à son serveur. Les titres et les numéros de fichiers locaux ne servent
jamais à associer deux contenus.

La synchronisation s'effectue en arrière-plan lors du changement de serveur et du
chargement du catalogue, sans retarder l'affichage des films et séries. L'accueil
et les films sont rafraîchis silencieusement après la synchronisation de la bascule.
Les appels de reprise et de fiches attendent la synchronisation pour conserver une
progression à jour (au plus une lecture complète toutes les 30 secondes). Après un enregistrement de progression ou une action vu/non vu,
l'app transmet en arrière-plan l'état du seul média concerné. La date du visionnage
est conservée : un historique ancien ne remplace pas une lecture plus récente.
À date exactement identique, chaque serveur conserve son état existant.

Les serveurs doivent disposer des routes authentifiées GET/POST `/api/progress/sync`.
Chaque requête utilise uniquement le jeton du compte du serveur destinataire.
L'import affecte seulement cet utilisateur, retrouve les médias de sa bibliothèque
et conserve leurs durées et leurs fichiers. Les épisodes terminés alimentent le
calcul existant du prochain épisode à reprendre.

Les serveurs restent autonomes : l'app assure le transfert, sans service central.
Un serveur indisponible ou d'une ancienne version n'empêche pas l'utilisation de
l'app. Une prochaine synchronisation retente le transfert depuis les historiques
conservés sur les serveurs. L'app n'entretient pas de copie locale supplémentaire :
la source doit redevenir accessible si sa progression n'a encore été transmise à
aucun autre serveur. Le rejeu des lectures téléchargées hors ligne reste assuré par
le mécanisme existant, puis déclenche ce même partage.

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

Les liaisons sont conservées sur le client, sans fédération ni transfert des mots de
passe entre serveurs. La synchronisation nécessite que l'app s'exécute ; un autre
appareil doit également enregistrer et lier les comptes concernés. Les serveurs et
l'app doivent être mis à jour. Le relais est automatique avec une interruption de
réouverture du flux, pas une commutation vidéo sans coupure.
