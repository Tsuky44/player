# ADR-0007 — Le téléviseur offre, il ne demande plus

- **Statut :** accepté
- **Date :** 2026-08-26
- **Portée :** la connexion d'un téléviseur à un compte. Remplace le chemin décrit à
  l'ADR-0003 §5 et §6 côté TV ; les endpoints d'appairage serveur restent en place pour le lien
  web `?tv=CODE`.

## Contexte

L'ADR-0003 §5 fait signer le téléviseur par appairage plutôt que par mot de passe, ce qui était la
bonne moitié du problème. L'autre moitié est restée : **ouvrir un appairage est un appel au
serveur**, et un téléviseur fraîchement installé n'a pas son adresse. Il n'a pas non plus de
clavier pour se la faire donner.

L'ADR-0003 §6 répond par un balayage du /24. Ça marche sur une topologie simple et sur aucune
autre : téléviseur sur le Wi-Fi et serveur sur un autre sous-réseau, VLAN invité, Wi-Fi isolant
les clients entre eux — dans tous ces cas le balayage revient vide et l'écran retombe sur « tapez
l'adresse à la télécommande », c'est-à-dire exactement ce qu'il existait pour éviter.

Le QR aggravait la chose plutôt que de la résoudre. Il encode `<serveur>/?tv=CODE`, donc il
suppose déjà l'adresse connue ; et scanné avec l'appareil photo natif, il ouvre **le navigateur**
du téléphone, pas l'application où l'utilisateur est connecté. Le navigateur n'a pas la session,
donc il faut se reconnecter — sur le chemin censé éviter les mots de passe.

## Décision

### 1. Le sens de l'échange est inversé

Le téléviseur n'essaie plus de joindre quoi que ce soit. Il **ouvre une écoute HTTP sur le réseau
local**, affiche en QR une adresse vers lui-même accompagnée d'un code à usage unique, et attend.
Le téléphone — qui connaît le serveur et détient déjà une session — scanne, et **livre les deux
moitiés manquantes** : l'adresse du serveur, et une session dessus.

C'est le seul canal disponible quand aucun serveur n'est connu des deux côtés : il faut bien que
l'un des deux appareils écoute, et celui qui ne sait rien est le mieux placé pour le faire.

L'écoute est délibérément minuscule et éphémère : port éphémère choisi par l'OS, ouverte
uniquement tant que l'écran de connexion est affiché, **une seule livraison acceptée**, et fermée
dès qu'elle arrive.

Ce qui la protège est le code à usage unique du QR, connu seulement de qui voit l'écran du
téléviseur — la même garantie que le code d'appairage, et ce qui empêche un tiers sur le même
réseau de pointer cet écran vers un serveur de son choix. La réponse HTTP est **écrite avant** que
l'écoute ne se ferme : l'inverse coupait la socket au milieu de la réponse, et le téléphone lisait
un échec sur un lien qui avait réussi.

### 2. Le scan se fait dans l'application, pas dans l'appareil photo

L'appareil photo natif ouvre un navigateur, et un navigateur n'a pas la session du téléphone —
c'était le vice du QR précédent. Le téléphone scanne donc depuis **Compte → Connecter un
téléviseur**, ce qui coûte une dépendance caméra (`mobile_scanner`) et la permission `CAMERA`.

Les features caméra sont déclarées `required="false"` dans le manifeste, sans quoi la permission
les rendrait implicitement obligatoires et **ferait disparaître l'app des téléviseurs** — le même
APK sert les deux.

Un scan fait quand même à l'appareil photo tombe sur une page servie par le téléviseur qui dit où
aller. Une page d'instructions vaut mieux qu'une erreur de navigateur.

### 3. La session du téléviseur est la sienne

Le téléphone ne recopie pas son jeton : il demande au serveur d'en créer un
(`POST /api/auth/device/session`, authentifié) et transmet celui-là. Déconnecter le téléviseur
plus tard ne doit pas déconnecter le téléphone.

L'endpoint s'exécute **sous l'identité de l'appelant**, ce qui est toute la garantie : le
téléviseur hérite exactement du compte qui a scanné son code. Il ne vérifie aucun code — le code
du QR est l'affaire du téléviseur, et c'est le téléviseur qui le contrôle à la livraison.

### 4. Le mot de passe reste le filet, et il sait chercher

Le formulaire reste à un bouton de l'écran TV : un foyer dont le seul appareil est le téléviseur
doit pouvoir entrer, et le tout premier compte d'un serveur vierge n'a personne pour l'approuver.

C'est ce chemin qui hérite du balayage réseau de l'ADR-0003 §6, sous la forme d'un bouton
« Détecter le serveur sur le réseau » sous le champ d'adresse. Le balayage était une réponse
insuffisante au problème principal ; il reste la bonne réponse à celui-ci.

## Conséquences

- **La TV ne demande plus jamais d'adresse de serveur sur le chemin principal.** Il n'y a plus de
  champ à remplir sur cet écran, ni de bouton qui en ouvre un.
- Plus de compte à rebours : rien n'expire. Le code ne vaut que tant que l'écran est affiché, et
  l'écoute meurt avec lui — un chronomètre à battre serait une contrainte inventée.
- L'APK grossit de la reconnaissance de codes-barres ML Kit, et le `minSdk` passe de 21 à 23,
  qui est le plancher de la bibliothèque. Android 6 (2015) : rien de vivant n'est en dessous, et
  `matchRefreshRate` demandait déjà M.
- Le téléphone et le téléviseur doivent être sur le **même réseau local**. C'était déjà vrai pour
  lire un film ; ça devient vrai aussi pour la connexion, et l'échec le dit avec ces mots.
- Les endpoints `device/start`, `poll`, `approve` et `deny` restent : le lien web `?tv=CODE` et
  l'écran d'approbation par code du téléphone s'appuient dessus. Le téléviseur, lui, ne les
  appelle plus.
