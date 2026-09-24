# ADR-0037 — Liens de partage publics, sans compte

- **Statut :** accepté, réalisé — testé automatiquement, pas encore essayé sur un vrai serveur
  depuis un réseau extérieur
- **Date :** 2026-09-24
- **Portée :** le serveur (`server/sharelinks`, `server/sharepage`, `server/handlers/media_shares.go`,
  `server/handlers/shared_media.go`, `server/playbackauth/share.go`, migration 14) et l'app
  (`app/lib/widgets/global/share_media_dialog.dart`, `share_media_button.dart`,
  `app/lib/screens/settings/pages/shares_page.dart`, le droit `share_media`)

## Contexte

On voulait partager un film ou un épisode avec quelqu'un qui n'a pas de compte : lui envoyer un
lien, qu'il ouvre dans son navigateur. Le créateur choisit s'il met un mot de passe, et si le lien
se détruit une fois le média vu.

Jusqu'ici, tout ce qui lit un média passe par un compte : le ticket de lecture
([playback-tickets](../playback-tickets.md)) est délivré à un utilisateur, et l'app web suppose
un compte à chaque étape (pistes, progression, reprise).

## Décision

### 1. Un droit à part : `share_media`

Un lien public fait lire, et souvent transcoder, le serveur pour un inconnu. C'est un droit
d'administration au sens de l'[ADR-0001](0001-user-permissions-and-invitations.md), géré dans
l'écran des utilisateurs. La migration 14 le donne à ceux qui avaient déjà tous les droits, pour
qu'un administrateur le reste. Le retirer supprime les liens du compte, comme retirer
`invite_users` révoque ses invitations.

### 2. Le lien : un code aléatoire gardé en empreinte

Le code fait 128 bits d'aléa. La table `media_shares` n'en garde que l'empreinte SHA-256, comme
les jetons de session ([ADR-0032](0032-durcissement-de-l-authentification.md)). Le code n'est donc
montré qu'une fois, à la création : la page « Liens de partage » permet de suivre et de couper un
lien, pas de le recopier. Le mot de passe, facultatif, est haché avec bcrypt.

L'adresse est `https://serveur/share#code`. Le code est dans le **fragment**, que le navigateur
n'envoie jamais au serveur : il n'apparaît dans aucun journal de proxy ni dans aucun en-tête
`Referer`. La page le présente elle-même dans le corps des requêtes `/api/shared/*`. Comme pour
les invitations, l'app compose l'adresse à partir de celle à laquelle elle est connectée, et
prévient quand elle n'est joignable que depuis le réseau local.

### 3. Usage unique : réservé au premier navigateur, détruit quand il a vu le média

Au choix du créateur, un lien est **réutilisable** jusqu'à son échéance, ou **détruit après
lecture**. Dans ce second cas :

- le premier navigateur qui ouvre le lien le **réserve** : il reçoit un jeton `viewer`, dont le
  serveur garde l'empreinte. Ce navigateur peut recharger la page ; un autre appareil reçoit `409` ;
- le lien est **détruit** quand ce navigateur atteint le seuil « vu », 90 %, le même que pour la
  progression d'un compte (`reachedWatchedThreshold`). Seul le navigateur qui lit peut le
  signaler : il faut son jeton et un ticket vivant du lien ;
- après la destruction, ce navigateur peut encore **renouveler son ticket pendant une heure**, le
  temps du générique : sur un film de trois heures, les dix derniers pour cent durent plus
  longtemps qu'un ticket.

Écarté : détruire le lien à la première ouverture. Un rechargement de page ou une coupure réseau
l'aurait perdu, pour une protection à peine meilleure puisque la réservation empêche déjà un
second appareil de l'ouvrir.

### 4. Une durée de validité en plus

24 heures, 7 jours, 30 jours ou sans limite ; 7 jours par défaut, et « détruire après lecture »
coché par défaut. Un lien expiré ne s'ouvre plus et ne renouvelle plus aucun ticket : la lecture
en cours s'arrête à l'échéance de son ticket, 15 minutes au plus.

### 5. Des tickets de lecture au nom du lien

`playbackauth` délivre des tickets dont le titulaire est un lien (`ShareID`) plutôt qu'un compte
(`UserID` à 0, qu'aucun compte ne porte). Le ticket ouvre les routes HLS habituelles, sans rien
changer à `streaming`. Un compte ne peut ni renouveler ni révoquer un ticket de lien, et ce ticket
ne compte pas comme « en train de lire » pour lui. Un lien tient au plus quatre lectures
simultanées. **Supprimer un lien révoque tous ses tickets** : une réponse déjà en cours s'arrête au
bloc suivant, comme pour un ticket de compte.

La lecture d'un visiteur n'écrit rien dans la progression ni dans l'historique du créateur : le
visiteur n'est pas lui. La page garde sa propre position dans le `localStorage` du navigateur.

### 6. Une page à part, pas l'app web

`GET /share` sert une page statique de quelques kilo-octets (`server/sharepage`), et non le bundle
Flutter : le visiteur vient souvent d'un téléphone, pour un seul média, et le lecteur de l'app
suppose un compte. La page :

- lit toujours en HLS **sans déclarer de capacités** : le serveur rend du H.264 + AAC stéréo en
  MPEG-TS, que tout navigateur lit, et recopie l'image quand elle est déjà en H.264 ;
- charge hls.js 1.4.10 depuis cdnjs, la même version et la même source que media_kit sur le web,
  avec la configuration du pont web de l'app ; Safari sans MSE lit le flux nativement ;
- rouvre une session au bon endroit pour un saut au-delà de ce que la session a produit ;
- n'autorise, par sa politique de sécurité, que ses propres fichiers, hls.js, les affiches et les
  flux du serveur ; elle est marquée `noindex` et `no-referrer`.

### 7. Routes publiques limitées

`/api/shared/open`, qui vérifie le mot de passe, a la limite de la connexion par adresse, plus un
seau par lien pour les mauvais mots de passe, comme le seau par compte de l'ADR-0032. Les autres
routes suivent le rythme d'une lecture. Tant qu'un mot de passe est exigé, `/api/shared/info` ne
dit pas quel média le lien ouvre.

## Conséquences

- **Pas de sous-titres ni de choix de piste audio sur la page** : elle lit la piste par défaut.
  Les ajouter demanderait d'ouvrir `/api/media/:id/tracks` et les sous-titres de session au ticket
  de lien.
- **Un visiteur qui bloque l'envoi de sa position empêche la destruction** d'un lien à usage
  unique. La réservation limite ce lien à son seul navigateur, et l'échéance finit par le fermer.
- **Le lien dépend de l'adresse de connexion de l'app.** Un lien créé depuis le réseau local ne
  marche pas dehors ; l'app le signale sans pouvoir le corriger, puisque le serveur ne connaît pas
  son adresse publique.
- **Un redémarrage du serveur coupe les lectures en cours** (les tickets vivent en mémoire), mais
  pas les liens : la page rouvre une lecture au rechargement, le lien réservé reconnaît son
  navigateur.
- **hls.js vient d'un CDN.** Sans accès à cdnjs, la page ne lit que sur Safari.
