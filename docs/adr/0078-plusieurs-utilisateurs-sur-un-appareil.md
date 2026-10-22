# ADR-0078 — Plusieurs utilisateurs d'un même serveur sur un appareil, et « Qui regarde ? »

- **Statut :** accepté. Testé en Dart (`app/test/user_choice_test.dart`,
  `app/test/profile_avatar_test.dart`) et en Go (`server/handlers/avatars_test.go`) ; les écrans
  n'ont pas encore été vus tourner sur une vraie télévision.
- **Date :** 2026-10-22
- **Portée :** l'app (`app/lib/screens/auth/user_choice_screen.dart`,
  `app/lib/screens/auth/add_user_screen.dart`, `app/lib/screens/auth/avatar_picker_screen.dart`,
  `app/lib/widgets/global/profile_disc.dart`, `app/lib/theme/profile_avatars.dart`,
  `app/lib/services/api/avatars.dart`, `app/lib/providers/auth_provider.dart`,
  `app/lib/services/server_registry.dart`, `app/lib/widgets/global/account_menu.dart`,
  `app/lib/main.dart`) et le serveur pour l'image de profil (`server/handlers/avatars.go`,
  migration 29, capacité `avatars`).

## Contexte

La télévision du salon sert à toute la famille, mais chacun a son compte sur le serveur : sa
progression, ses listes, ses droits. Le carnet de comptes (ADR-0013) savait déjà en tenir plusieurs
sur un même serveur — l'identifiant d'un compte est dérivé de l'adresse **et** du nom — mais l'app
ne l'envisageait pas : le menu affichait « Passer sur maison.local » deux fois, l'ajout d'un compte
par mot de passe rendait le premier compte de l'adresse au lieu du nouveau, et rien ne disait qui
regardait au lancement.

## Décision

### Une personne est un compte du carnet ; « Qui regarde ? » liste ceux du serveur actif

Pas de notion de profil côté serveur : chaque personne a déjà un vrai compte, et le carnet garde le
jeton de chacun. Changer d'utilisateur, c'est la bascule d'ADR-0013 — rien à retaper, et
`onServerChanged` vide ce que la personne précédente avait chargé.

Deux comptes sont « du même serveur » (`ServerRegistry.sameServer`) quand leurs identités de serveur
(ADR-0017) concordent, ou à défaut leurs adresses. Les personnes du serveur actif passent par
**Changer d'utilisateur**. La partie « Passer sur… » du menu liste chaque **autre serveur une
seule fois** (`ServerRegistry.otherServers`) ; quand on y a plusieurs comptes, le choisir ouvre
« Qui regarde ? » sur ce serveur au lieu d'entrer dans la session de la première personne venue.

### Au lancement, partout, dès qu'il y a deux personnes sur ce serveur

Quand le serveur de démarrage (principal ou dernier actif) tient au moins deux comptes sur
l'appareil, `tryAutoLogin` s'arrête **avant** d'ouvrir une session et l'app affiche « Qui
regarde ? ». Ouvrir d'abord celle du dernier utilisateur puis basculer aurait chargé son accueil —
ses reprises, ses listes — sous les yeux de quelqu'un d'autre. Le choix reprend ensuite le chemin
ordinaire du démarrage, replis hors ligne et serveur principal compris.

Le choix a été fait pour tous les appareils, pas seulement la télévision : un téléphone qui tient
deux comptes du même serveur est un appareil partagé lui aussi. Un appareil d'une seule personne
n'a qu'un compte par serveur et ne voit jamais l'écran.

Aucun code ne protège un profil : chacun a ouvert sa session sur l'appareil, et c'est à ce moment-là
que le mot de passe a été demandé. Un verrou par profil serait une autre décision.

### Ajouter quelqu'un

Depuis « Qui regarde ? », **Ajouter** ouvre une page à part (`AddUserScreen`) qui ne demande que
l'identifiant et le mot de passe : on ajoute quelqu'un au serveur qu'on a sous les yeux, l'adresse
n'a pas à être tapée. L'écran des serveurs, avec son adresse, sa détection et sa demande d'accès,
reste celui d'un *autre* serveur. Sur une télévision, la page propose aussi l'appairage par le
téléphone (ADR-0003, `TvLoginScreen(addingUser: true)`) : la personne scanne avec son propre
téléphone. L'app passe ensuite sur le nouveau compte : c'est pour lui qu'on vient de l'ouvrir.

Le formulaire de connexion ordinaire n'est pas réutilisé une fois une session ouverte : il remplace
la session active sans vider ce qu'elle a chargé.

### L'image de profil est gardée par le serveur

Chacun choisit une image : un avatar de la **galerie** de l'app, une **photo**, ou l'initiale sur
sa teinte. Elle est enregistrée sur le serveur (`users.avatar`, migration 29), pour suivre le
compte sur tous ses appareils ; une image par appareil aurait obligé à la rechoisir sur la
télévision, le téléphone et l'ordinateur.

- **La galerie est dessinée par l'app** : des icônes Phosphor pleines, déjà embarquées, sur des
  dégradés (`ProfileAvatars`). Elle s'affiche hors ligne et reste nette à toutes les tailles. Le
  serveur ne garde que la clé (`preset:cat`), qu'il borne à `[a-z0-9-]{1,32}` sans connaître la
  liste ; une clé que l'app ne connaît plus retombe sur l'initiale.
- **La photo** est recadrée au carré et réduite à 384 px **par l'app**, en PNG, avant l'envoi :
  le serveur n'a pas de quoi redimensionner sans dépendance. Il vérifie qu'elle se décode (JPEG ou
  PNG, 1 Mo et 2048 px au plus) et la garde dans sa propre table (`user_avatar_photos`), pour que
  lire un compte ne charge jamais ses octets. `users.avatar` vaut alors `photo:<version>`, et la
  version change à chaque envoi : c'est elle qui périme les copies des apps.
- **La photo se lit avec une session du serveur** (`GET /api/users/:id/avatar`), jamais sans : une
  photo de quelqu'un n'est pas un fichier public comme `/stream`. L'app la lit avec le jeton du
  compte concerné et la garde en mémoire (`AvatarPhotoCache`), puisque le cache d'images partagé
  ne présente qu'un en-tête par adresse.
- **On change l'image de n'importe quelle personne de l'appareil**, depuis « Qui regarde ? » :
  l'appel part sur son serveur avec **son** jeton, sans ouvrir sa session. Le crayon apparaît au
  survol de la souris ; au tactile et à la télécommande, **Gérer les profils** met toutes les
  pastilles en modification, et la touche menu y mène aussi. Une télévision ne propose pas de
  photo : elle n'a pas de galerie où la prendre.
- Le carnet retient la dernière image connue de chaque compte (`ServerAccount.avatar`), pour que
  « Qui regarde ? » l'affiche avant qu'aucune session soit ouverte. Elle est relue à chaque
  `/api/auth/me`.

## Conséquences

- **Mettre à jour le serveur** pour les images de profil : un serveur plus ancien refuse le choix,
  et l'app le dit (« Ce serveur doit être mis à jour… »). Tout le reste — « Qui regarde ? »,
  l'ajout, la bascule — marche avec un serveur d'avant.

- `addServerWithPassword` retrouve le compte par `ServerAccount.idFor(adresse, nom)` et plus par
  l'adresse seule, qui désignait le premier utilisateur du serveur.
- Lier deux comptes n'est plus proposé entre deux comptes du même serveur : les liens d'ADR-0017
  vont d'un serveur à un autre.
- Les **téléchargements** restent rangés par serveur (ADR-0013) : les personnes d'un même serveur
  voient les mêmes fichiers sur l'appareil. La position gardée avec un fichier est celle de la
  dernière personne qui l'a lu, et la progression d'un épisode regardé hors ligne part au serveur
  avec le jeton de la personne active au retour du réseau. Séparer les téléchargements par personne
  reste à faire si le partage gêne.
- Une session ouverte par un autre chemin que le choix (un compte ajouté depuis l'écran du
  lancement) répond à la question : `AuthProvider.notifyListeners` referme alors « Qui regarde ? ».
