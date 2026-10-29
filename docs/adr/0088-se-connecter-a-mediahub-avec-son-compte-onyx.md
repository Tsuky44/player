# ADR-0088 — Se connecter à MediaHub avec son compte Onyx

- **Statut :** accepté
- **Date :** 2026-10-29
- **Portée :** `server/mediahub/sso.go`, `server/handlers/mediahub_sso.go`, les routes
  `POST /api/integrations/mediahub/sso` et `/sso/redeem`, la capacité `mediahub_sso`,
  `contract/mediahub/onyx_*.json`, `contract/mediahub_sso.json`, et côté app `MediaHubTicket`
  (`models/my_request.dart`), `services/api/my_requests.dart` et le bouton « Ouvrir MediaHub » de
  `screens/requests/my_requests_screen.dart`. Prolonge l'ADR-0087.

## Contexte

MediaHub retrouvait le compte d'un utilisateur d'Onyx par son nom (`X-Player-Username`) et gardait
ses propres mots de passe : deux comptes à tenir, et un lien qui ne tient que si les deux noms
s'écrivent pareil. MediaHub ajoute un fournisseur de connexion « Onyx » et lie chaque compte
MediaHub à l'id du compte Onyx.

Il faut deux chemins. Depuis le site de MediaHub, l'utilisateur tape son nom et son mot de passe
Onyx : MediaHub les vérifie avec `POST /api/auth/login`, et `POST /api/auth/otp/login` pour l'étape
OTP (ADR-0041). Depuis l'app Onyx, l'utilisateur est déjà connecté : lui redemander son mot de
passe dans un navigateur serait la pire étape du parcours.

## Décision

- **L'id est le lien.** `user.id` est un `INTEGER PRIMARY KEY AUTOINCREMENT` : jamais réutilisé,
  même après une suppression. Aucune route ne renomme un compte, et `username` sert de nom
  d'affichage. Rien n'est ajouté à `/api/auth/me` ni au login. Onyx envoie déjà `X-Player-Id` à
  chaque appel fait au nom d'un compte (ADR-0075), et un test de contrat l'épingle désormais pour
  MediaHub aussi.
- **Un code opaque, racheté de serveur à serveur.** L'app appelle `POST
  /api/integrations/mediahub/sso` avec sa session. Onyx tire 32 octets aléatoires, gardés en mémoire
  60 s pour ce compte, et rend `{url, expires_in}`, où `url` vaut
  `{mediahub_url}/api/auth/onyx/sso?code=…`. Le navigateur y va. MediaHub appelle alors `POST
  /api/integrations/mediahub/sso/redeem`, avec `Authorization: Bearer <clé d'intégration>` et
  `{"code"}`, et reçoit `{"user": …}`, le même objet que `/api/auth/me`. Onyx efface le code sous
  le même verrou qu'il le lit : un code ne s'échange qu'une fois, même par deux rachats
  simultanés.
- **Pourquoi pas un jeton signé.** Avec un JWT, MediaHub aurait dû vérifier une signature et tenir
  une liste anti-rejeu pendant la durée de vie du jeton. Avec le rachat, Onyx reste seul juge, et
  un code lu dans un historique ou un journal de proxy ne dit rien à qui n'a pas la clé
  d'intégration. Le prix est un aller-retour de MediaHub vers Onyx, déjà nécessaire pour la
  connexion par mot de passe.
- **Où se fait la décision.** Onyx n'impose aucun droit pour tirer un code : c'est MediaHub qui
  décide qui entre et avec quel rôle, à partir de `is_owner` et `permissions`. Le code se tire au
  clic, jamais à l'avance. Le rachat est limité comme une connexion (`LoginLimiter`). Les codes en
  attente sont bornés à 1024 : au-delà, le plus ancien part.
- **Refus.** `503` si l'adresse ou la clé de MediaHub manquent ; `501` quand le compagnon est
  OnyxHub, qui n'a pas de route d'atterrissage (une adresse muette n'empêche rien, puisque le
  rachat va dans l'autre sens) ; au rachat, `401` sans la clé et `410` pour un code inconnu,
  expiré, déjà racheté, ou dont le compte a été supprimé.
- **Dans l'app.** « Mes demandes » affiche un bouton « Ouvrir MediaHub » quand le serveur annonce
  `mediahub_sso` et que le compagnon est MediaHub. Sur mobile, `openExternalUrl` ne sait pas
  confier une adresse au navigateur : le lien est alors copié, et un message dit de l'ouvrir dans la
  minute.

## Conséquences

- Les formats que MediaHub lit d'Onyx sont épinglés sous `contract/mediahub/onyx_*.json` (login,
  étape OTP, me, rachat) par `TestMediaHubLoginContract`. Le billet rendu à l'app est épinglé par
  `contract/mediahub_sso.json`. Pour les régénérer : `ONYX_UPDATE_CONTRACT=1`.
- Un redémarrage d'Onyx perd les codes en attente : il suffit de cliquer à nouveau.
- Onyx ne connaît MediaHub que par `mediahub_url`, l'adresse que le serveur appelle. Si le
  navigateur doit passer par une autre adresse (réseau interne contre adresse publique), il faudra
  un second réglage.
- La connexion par mot de passe depuis MediaHub passe par la même IP pour tous ses utilisateurs.
  Elle partage donc la limite de 10 connexions toutes les 6 s par IP.
