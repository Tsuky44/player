# ADR-0037 — Liens de partage publics, sans compte

- **Statut :** accepté, réalisé — testé automatiquement, pas encore essayé sur un vrai serveur
  depuis un réseau extérieur
- **Date :** 2026-09-24
- **Portée :** le serveur (`server/sharelinks`, `server/handlers/media_shares.go`,
  `server/handlers/shared_media.go`, `server/handlers/share_scope.go`,
  `server/playbackauth/share.go`, migration 14) et l'app
  (`app/lib/widgets/global/share_media_dialog.dart`, `share_media_button.dart`,
  `app/lib/screens/settings/pages/shares_page.dart`, `app/lib/screens/shared_link/`,
  `app/lib/services/api/shared_link_client.dart`, le droit `share_media`)

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
visiteur n'est pas lui. L'app invitée garde sa propre position dans le stockage du navigateur.

### 6. Le lecteur Onyx, en invité

`/share` sert l'app web elle-même. Au démarrage, `main.dart` reconnaît l'adresse
(`sharedLinkCode`) et lance l'app **en invité** (`screens/shared_link/`) : une page qui montre le
média, demande le mot de passe, puis ouvre le **lecteur Onyx habituel** (`PlayerScreen`), avec ses
pistes audio, ses sous-titres, sa qualité et ses aperçus.

Le lecteur tourne sur un `SharedLinkApiClient` (`services/api/shared_link_client.dart`) :

- son registre de comptes est vide : même si ce navigateur est connecté par ailleurs à ce serveur,
  le visiteur n'utilise aucun compte ;
- le ticket de lecture vient de `/api/shared/open` et se renouvelle par `/api/shared/renew` ;
- les pistes viennent de `/api/shared/tracks`, qui exige un ticket vivant du lien ;
- la position est gardée sur l'appareil et envoyée à `/api/shared/progress` ;
- ce qui suppose un compte (historique, épisode suivant, séance « Regarder ensemble », journal)
  est vide ou masqué (`ApiClient.isGuest`).

Le reste — HLS, Direct Play, sous-titres, aperçus — passait déjà par le ticket seul.

La page d'accueil du lien porte comme nom de route le code lui-même : sous le « / » habituel, le
routeur de Flutter réécrirait l'adresse en `/share#/`, et un rechargement perdrait le lien.

Écarté : une page HTML légère servie par le serveur, essayée d'abord. Elle chargeait plus vite,
mais sans les pistes, les sous-titres ni l'habillage du lecteur Onyx.

### 7. Routes publiques limitées

`/api/shared/open`, qui vérifie le mot de passe, a la limite de la connexion par adresse, plus un
seau par lien pour les mauvais mots de passe, comme le seau par compte de l'ADR-0032. Les autres
routes suivent le rythme d'une lecture. Tant qu'un mot de passe est exigé, `/api/shared/info` ne
dit pas quel média le lien ouvre.

### 8. Une saison ou une série entière (ajout du 2026-10-03)

Un lien peut aussi désigner une **saison** ou une **série** : `media_id` est alors celui de la
saison ou de la série, sans migration. Il ouvre les épisodes lisibles qu'elle contient **au moment
de l'ouverture** — un épisode arrivé après la création du lien en fait partie, un épisode sans
fichier n'y figure pas (`server/handlers/share_scope.go`).

- La page du lien liste les épisodes (`episodes` dans `/api/shared/info`), et le visiteur en
  choisit un : `/api/shared/open` reçoit son `media_id`, vérifie qu'il appartient au lien, et
  délivre un ticket **pour cet épisode seulement**. Les routes de la lecture (`tracks`,
  `progress`) nomment l'épisode de la même façon ; le ticket prouve qu'il fait partie du lien.
- Avec un mot de passe, `/api/shared/info` ne dit toujours rien. `/api/shared/contents` vérifie
  le mot de passe, avec les limites de l'ouverture, et rend la liste sans rien délivrer : la page
  apprend là seulement qu'elle a affaire à une série.
- **Jamais à usage unique.** « Détruit après lecture » suppose un média : le serveur refuse
  `single_use` sur une saison ou une série, et l'app ne le propose pas. Reste l'échéance, et la
  suppression du lien. Écarté : détruire le lien quand tous les épisodes ont été vus — il aurait
  fallu garder côté serveur la progression d'un visiteur sans compte, épisode par épisode.
- La position de reprise est gardée dans le navigateur, une par épisode.
- Le lecteur invité n'enchaîne pas sur l'épisode suivant : le visiteur revient à la liste.

### 9. Dans l'app installée, toujours sans compte (ajout du 2026-10-05)

Quelqu'un qui a installé l'app ouvre le même lien dedans, sans compte ni serveur enregistré :
l'écran de connexion propose « Ouvrir un lien de partage », où il colle le lien
(`app/lib/screens/shared_link/shared_link_guest.dart`). Hors du web, la page ne vient d'aucun
serveur : c'est le lien collé qui dit où il mène (`SharedLinkAddress`), et le
`SharedLinkApiClient` est construit sur cette adresse au lieu de celle de la page.

- La page du lien et son lecteur vivent dans **un navigateur à part**, sous les fournisseurs du
  lien (`SharedLinkGuestScope`). Le client de l'app, son serveur et ses comptes ne sont pas
  touchés : fermer la page rend l'écran de connexion tel qu'il était.
- Le lecteur invité **n'ouvre jamais un téléchargement de l'appareil** : l'identifiant du média
  est celui d'un autre serveur et peut désigner ici un autre film. Pour la même raison, les
  caches de fiches et de pistes sont vidés à l'entrée et à la sortie.
- Pas sur un téléviseur, qui n'a pas de presse-papiers où recevoir le lien.

Écarté pour l'instant : ouvrir l'app au toucher du lien (App Links, Universal Links). Ils se
déclarent par nom de domaine dans l'app, et chaque serveur a le sien. Un schéma `onyx://`
resterait possible, mais un lien `https` doit d'abord marcher partout, navigateur compris.

**Une série en double** (ajout du 2026-10-05) : le lien d'une série est posé sur sa fiche
canonique (`shareScopeID`), celle à laquelle pendent les saisons et que l'app affiche. Posé sur un
doublon, il n'ouvrait que la saison restée dessous. Un lien déjà créé sur un doublon est relu de
la même façon à l'ouverture.

## Conséquences

- **Le lien d'une série ouvre beaucoup à la fois.** La borne de quatre lectures simultanées par
  lien (§5) tient toujours, mais rien ne limite le nombre d'épisodes vus d'ici l'échéance.

- **Le visiteur charge l'app web entière** (plusieurs mégaoctets) pour un seul média : quelques
  secondes de plus au premier affichage, surtout sur un téléphone.
- **Un visiteur qui bloque l'envoi de sa position empêche la destruction** d'un lien à usage
  unique. La réservation limite ce lien à son seul navigateur, et l'échéance finit par le fermer.
- **Le lien dépend de l'adresse de connexion de l'app.** Un lien créé depuis le réseau local ne
  marche pas dehors ; l'app le signale sans pouvoir le corriger, puisque le serveur ne connaît pas
  son adresse publique.
- **Un redémarrage du serveur coupe les lectures en cours** (les tickets vivent en mémoire), mais
  pas les liens : la page rouvre une lecture au rechargement, le lien réservé reconnaît son
  navigateur.
- **Sans bundle web embarqué** (un serveur compilé sans `scripts/build-web.sh`), `/share` ne
  répond pas.
