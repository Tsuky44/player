# ADR-0020 — Connexion par QR code sur le web et le desktop

- **Statut :** accepté
- **Date :** 2026-09-15
- **Portée :** l'écran de connexion du web, du desktop et des tablettes ; le scanner du téléphone.
  Le téléviseur garde le lien direct de l'ADR-0007.

## Contexte

Le téléviseur se connecte sans mot de passe : il affiche un QR, un téléphone déjà connecté le
scanne. Partout ailleurs — navigateur, application Windows, macOS, Linux — il fallait encore taper
identifiant et mot de passe, alors qu'un téléphone connecté est presque toujours à portée de main.

Le lien direct de l'ADR-0007 ne se transpose pas : il repose sur une écoute HTTP locale, et un
onglet de navigateur ne peut pas écouter sur une socket.

## Décision

### 1. Le flux d'appairage serveur, pas le lien direct

Ces écrans connaissent déjà leur serveur : le navigateur a été servi par lui, et le desktop a le
champ d'adresse juste à côté. Le problème que résolvait le lien direct — un appareil qui ignore
l'adresse du serveur — ne se pose donc pas. L'écran ouvre un appairage ordinaire
(`device/start`), affiche `<serveur>/?tv=CODE` en QR et interroge `device/poll`. C'est le
flux de l'ADR-0003 §5, resté en place côté serveur : **aucune modification serveur**.

Le code est renouvelé en silence à son expiration plutôt qu'affiché comme expiré : la personne
regarde un écran de connexion, pas un chronomètre.

### 2. Le panneau est à côté du formulaire, pas à sa place

Le QR est proposé en mode connexion (pas en inscription ni en demande d'accès), à droite du
formulaire quand la largeur le permet, en dessous sinon. Il n'apparaît :

- **pas sur un téléphone** (plus petit côté < 600 px, hors desktop) — c'est lui qui scanne ;
- **pas sur un téléviseur** — il a son propre écran ;
- **pas sur un serveur vierge** — personne n'existe pour approuver.

Tant que l'adresse ne répond pas, le panneau le dit au lieu de tourner.

### 3. Un seul scanner côté téléphone

« Compte → Connecter un appareil » lit les deux formes de QR : l'offre d'un téléviseur
(`http://<tv>:<port>/link?c=…`) et le lien d'appairage (`…/?tv=CODE`). Le second mène à l'écran de
confirmation existant, qui nomme l'appareil avant tout accord.

Seul le code est utilisé, et uniquement auprès du serveur du téléphone : rien n'est envoyé à
l'adresse contenue dans le QR. Si le code est introuvable et que le lien vient d'une autre
adresse, l'erreur le signale — sans conclure, un proxy et une IP locale pouvant désigner le même
serveur.

## Conséquences

- Comme tout login par QR, la méthode expose au hameçonnage « scannez ce code » : quelqu'un
  envoie son QR et récupère la session approuvée. L'écran de confirmation l'écrit en toutes
  lettres : n'accepter qu'un code affiché en ce moment sur un appareil devant soi.
- L'écran de confirmation et le scanner parlent d'« appareil » et non plus de « téléviseur ».
- Le scan à l'appareil photo natif continue d'ouvrir le web app avec `?tv=CODE`, comme avant.
