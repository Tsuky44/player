# ADR-0078 — Plusieurs utilisateurs d'un même serveur sur un appareil, et « Qui regarde ? »

- **Statut :** accepté. Testé en Dart (`app/test/user_choice_test.dart`) ; l'écran n'a pas encore
  été vu tourner sur une vraie télévision.
- **Date :** 2026-10-22
- **Portée :** l'app (`app/lib/screens/auth/user_choice_screen.dart`,
  `app/lib/providers/auth_provider.dart`, `app/lib/services/server_registry.dart`,
  `app/lib/widgets/global/account_menu.dart`, `app/lib/screens/auth/tv_login_screen.dart`,
  `app/lib/main.dart`). Rien côté serveur.

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
(ADR-0017) concordent, ou à défaut leurs adresses. Les comptes d'un autre serveur restent dans la
partie « Passer sur… » du menu ; ceux du serveur actif passent par **Changer d'utilisateur**.

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

Depuis « Qui regarde ? », **Ajouter** ouvre, sur une télévision, l'appairage par le téléphone
(ADR-0003, `TvLoginScreen(addingUser: true)`) : la personne scanne avec son propre téléphone, c'est
son compte qui arrive. Ailleurs — et sur une télévision LG, qui ne peut pas écouter le téléphone
(ADR-0076) — le formulaire du carnet, adresse déjà remplie. L'app passe ensuite sur le nouveau
compte : c'est pour lui qu'on vient de l'ouvrir.

Le formulaire de connexion ordinaire n'est pas réutilisé une fois une session ouverte : il remplace
la session active sans vider ce qu'elle a chargé.

## Conséquences

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
