# ADR-0017 — Serveurs liés : les liens et la progression passent par les serveurs

- **Statut :** accepté
- **Date :** 2026-09-14
- **Portée :** serveur (fédération entre serveurs, liens de comptes, transmission de la
  progression) et app (carnet, écran Serveurs, paramètres d'administration).
- **Remplace en partie :** ADR-0013 (« aucune fédération entre serveurs ») et le fonctionnement
  décrit dans `docs/progression-multi-serveurs.md` avant cette date (liens gardés sur l'appareil,
  synchronisation faite par l'app).

## Contexte

Les liens entre comptes étaient gardés **sur l'appareil**, et c'était l'app qui lisait la
progression d'un serveur pour l'écrire sur l'autre. Trois conséquences gênantes :

- un lien fait sur le téléphone n'existait pas sur la télévision : il fallait tout refaire sur
  chaque appareil, et un appareil connecté à un seul des deux serveurs ignorait l'autre ;
- la progression ne passait d'un serveur à l'autre que pendant qu'une app tournait, avec les
  deux jetons en main ;
- les administrateurs n'avaient aucune prise sur le fait que leur serveur échange avec un autre.

## Décision

### Les serveurs se lient, une fois par paire, avec l'accord des deux administrateurs

Chaque serveur a une identité stable (`server_id`, générée au premier démarrage, rangée dans
`app_settings`) exposée par `GET /api/federation/info`. Un serveur lié est reconnu à cette
identité, pas à son adresse.

Une paire (`peer_servers`) porte un secret partagé, présenté à chaque appel entre serveurs
(`X-Onyx-Server` + `Authorization: Bearer <secret>`). Elle n'a cours que lorsqu'un administrateur
de **chaque** côté l'a acceptée (`local_approved` et `remote_approved`), dans **Paramètres →
Serveurs liés** (droit `manage_settings`). L'accord vaut pour la paire : un deuxième utilisateur
qui lie ses comptes entre les deux mêmes serveurs n'attend plus personne.

Refuser ou retirer la paire supprime les liens de comptes qui en dépendent, des deux côtés quand
l'autre serveur répond. L'historique déjà transmis reste.

### La personne lie ses comptes elle-même, sans qu'un jeton change de serveur

1. L'app demande au serveur B un **code de liaison** (`POST /api/links/code`, avec le jeton de B) :
   256 bits, dix minutes, usage unique.
2. Elle le remet au serveur A (`POST /api/links`, avec le jeton de A), avec l'adresse de B et
   l'adresse de A telles qu'elle les joint.
3. A appelle B lui-même (`POST /api/federation/claim`) : B vérifie le code, crée la paire en attente
   si elle n'existe pas, et enregistre le lien ; A fait de même de son côté.

Détenir un code émis par B pour un compte, c'est prouver qu'on détient ce compte. La route de
réclamation est ouverte — la paire n'existe pas encore — mais n'accepte rien sans ce code. Un compte
est lié à au plus un compte par serveur distant.

Aucune validation d'administrateur n'est demandée par lien de compte : la personne prouve qu'elle
possède les deux comptes, et les administrateurs ont déjà dit oui à la paire.

### La progression est transmise par les serveurs

Un journal `progress_changes`, tenu par **déclencheurs** SQLite sur `progressions`, numérote chaque
modification — lecture, vu/non vu, rejeu hors ligne, import d'un serveur lié — sans qu'aucun
handler n'ait à y penser. Chaque lien garde ce qu'il a déjà transmis (`account_links.pushed_seq`).

Une tâche de fond (`RunFederation`, toutes les cinq secondes et à chaque réveil) envoie à chaque
serveur lié actif les changements au-delà de ce curseur (`POST /api/federation/progress`), par lots
de 500, avec l'identité portable déjà utilisée (TMDB, saison, épisode). Le receveur applique la même
règle que l'import existant : seule une entrée **strictement plus récente** est écrite.

C'est ce qui arrête les échos : une entrée renvoyée à son serveur d'origine porte la même date, ne
modifie rien, donc n'entre pas au journal et ne repart pas. C'est aussi ce qui fait suivre la
progression de proche en proche (A ↔ B ↔ C).

Un serveur injoignable accumule simplement du retard sur le curseur : à son retour il reçoit tout,
sans file d'attente à entretenir. Les échecs espacent les tentatives jusqu'à cinq minutes et sont
affichés à l'administrateur. Un `404` du receveur (lien inconnu là-bas) supprime le lien ; un `401`
(paire inconnue là-bas) repasse la paire en attente.

À la création, le curseur est à zéro : le premier lien transmet tout l'historique existant.

### Ce que l'app garde

- **Le carnet reste par appareil** (ADR-0013) : chaque appareil garde ses propres sessions. Un
  serveur lié depuis un autre appareil apparaît dans **Serveurs → Vos autres serveurs**, avec
  l'adresse et l'identifiant pré-remplis ; il faut y entrer son mot de passe **une fois par
  appareil**. Une session automatique ouverte par le serveur lié a été écartée : elle aurait permis
  à un serveur compromis d'ouvrir une session sur les comptes liés de l'autre.
- **Une copie des liens** (`GET /api/links` pour chaque compte), persistée, sert à afficher l'état
  des liens et au relais de lecture, qui en a besoin précisément quand un serveur ne répond plus.
  Les comptes du carnet sont rapprochés des liens par identité de serveur et numéro de compte.
- Après l'ajout d'un serveur avec un mot de passe, l'app **propose** de le lier au compte actif. Elle
  ne lie rien d'office : un appareil partagé peut tenir les comptes de plusieurs personnes.
- La synchronisation par l'app (`ProgressSync`) est supprimée. Les liens gardés sur l'appareil par
  les versions précédentes sont remontés aux serveurs au premier rafraîchissement, puis oubliés.

## Conséquences

- **Les deux serveurs doivent pouvoir se joindre.** L'adresse transmise est celle qu'utilisait
  l'appareil ; si elle n'est joignable que depuis le réseau local de l'appareil, l'administrateur la
  corrige dans **Serveurs liés → Modifier l'adresse**.
- Les routes `GET/POST /api/progress/sync` restent en place pour les apps d'anciennes versions.
- `POST /api/links` fait émettre au serveur des requêtes vers une adresse fournie par un utilisateur
  connecté. Seules `/api/federation/info` et `/api/federation/claim` sont appelées et la réponse est
  bornée, mais c'est une surface à garder en tête.
- Le secret de la paire est stocké en clair des deux côtés, comme les jetons de session : chacun doit
  pouvoir le présenter à l'autre.
- Mettre à jour les deux serveurs et l'app. Un serveur d'une version précédente ne répond pas à
  `/api/federation/info` et le lien est refusé avec un message explicite.
