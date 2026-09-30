# ADR-0041 — Validation en deux étapes par code TOTP, politique choisie par l'administrateur

- **Statut :** accepté. En place et testé.
- **Date :** 2026-09-30
- **Portée :** le package `server/otp`, la migration 15 (`server/database/migrations.go`), la
  connexion (`server/handlers/auth.go`, `server/handlers/otp.go`), le réglage `otp_policy`
  (`server/config/settings.go`), et côté app `models/otp.dart`, `services/api/otp.dart`,
  `widgets/global/otp_code_dialog.dart`, la page « Mon compte » et la page « Utilisateurs ».

## Contexte

Un compte Onyx ne tenait qu'à son mot de passe. Un mot de passe réutilisé ailleurs, ou deviné
malgré les limites de débit (ADR-0032), ouvrait le compte, et celui d'un administrateur ouvrait le
serveur entier. Les administrateurs voulaient pouvoir exiger un second facteur, de tout le monde ou
des seuls comptes qui administrent, et pouvoir aussi l'éteindre.

## Décision

- **Un code TOTP (RFC 6238)** : SHA-1, six chiffres, trente secondes, une période de tolérance de
  chaque côté. Ce sont les paramètres que toutes les applications d'authentification comprennent.
  Un code accepté ne se rejoue pas : `totp_last_step` retient la dernière période acceptée, et
  l'écriture qui la consomme est conditionnelle, donc deux requêtes simultanées ne passent pas
  toutes les deux.
- **Dix codes de secours** à usage unique, remis une seule fois, gardés en empreinte SHA-256.
- **Une politique pour tout le serveur**, réglée par `manage_settings` dans `/api/settings` :
  `disabled` (personne ne peut l'activer, la connexion ne demande jamais de code, même aux comptes
  qui en ont un), `optional` (par défaut), `admins` (imposée au propriétaire et aux titulaires de
  `manage_settings`, `manage_library` ou `manage_users`), `everyone`.
- **La connexion s'arrête entre le mot de passe et le code.** `POST /api/auth/login` répond alors
  401 avec un objet `otp` (un jeton d'étape, et pour une configuration imposée le secret et son
  URI `otpauth://`). `POST /api/auth/otp/login` termine avec ce jeton et le code. Une étape vit
  cinq minutes, admet cinq essais, et ses échecs comptent contre le compte comme ceux du mot de
  passe. Le 401 porte un message lisible pour les versions de l'app qui ne connaissent pas l'étape.
- **Un compte à qui la politique impose un code qu'il n'a pas le configure pendant la connexion**,
  avant qu'aucune session n'existe. Il n'y a pas de fenêtre où le mot de passe seul donne accès.
- **Rien n'est activé avant un premier code juste**, pour qu'un QR code mal scanné ne ferme pas la
  porte à son titulaire. Désactiver son code ou tirer de nouveaux codes de secours redemande le
  mot de passe.
- **Un titulaire de `manage_users` peut retirer le code d'un autre compte**, sauf celui du
  propriétaire, que seul le propriétaire touche.

## Conséquences

- **Le secret TOTP est en clair dans `player.db`.** Le serveur doit pouvoir recalculer le code, et
  une clé de chiffrement vivrait à côté de la base. Une copie de la base livre donc les secrets,
  mais pas les mots de passe (bcrypt) : le second facteur protège contre un mot de passe deviné ou
  réutilisé, pas contre le vol de la base.
- **Les sessions déjà ouvertes ne sont pas fermées quand la politique se durcit.** Un téléviseur
  appairé ne saurait pas taper un code. L'obligation s'applique à la connexion suivante. Pour
  l'imposer tout de suite, l'administrateur déconnecte les appareils depuis sa page.
- **L'appairage par QR (ADR-0003, ADR-0020) et les demandes d'accès (ADR-0013) ne demandent pas de
  code** : la session y est accordée par un appareil déjà connecté ou par un administrateur.
- **Les étapes vivent en mémoire.** Un redémarrage les annule, et il suffit de recommencer la
  connexion.
- **Le propriétaire qui perd son téléphone et ses codes de secours** repasse la politique à
  `disabled` dans la base : `UPDATE app_settings SET value = 'disabled' WHERE key = 'otp_policy'`,
  puis redémarre le serveur. Son secret reste en base et redevient exigé si la politique change de
  nouveau : il le retire depuis sa page « Mon compte » une fois connecté.
