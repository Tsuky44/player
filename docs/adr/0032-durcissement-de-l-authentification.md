# ADR-0032 — Jetons de session hachés et limites de débit sur les routes publiques

- **Statut :** accepté. En place et testé.
- **Date :** 2026-09-23
- **Portée :** les sessions de connexion (`server/database/session_tokens.go`, migration 13,
  `server/handlers/sessions.go`), les routes ouvertes sans compte (`server/handlers/ratelimit.go`,
  `server/main.go`), l'inscription (`server/handlers/auth.go`), la taille des corps de requête
  (`server/middleware/body_limit.go`) et les appels vers une adresse saisie par un utilisateur
  (`server/httpx`).

## Contexte

Une revue du serveur a relevé plusieurs failles :

- **Les jetons de session étaient en clair dans la base.** Une copie de `player.db` suffisait pour
  se connecter à tous les comptes.
- **Aucune route publique n'avait de limite de débit.** On pouvait essayer des mots de passe sans
  frein, et créer sans limite des appairages et des demandes d'accès.
- **La connexion répondait plus vite pour un compte inexistant**, ce qui révélait les noms
  d'utilisateur.
- **L'inscription n'était pas atomique.** Deux inscriptions simultanées sur un serveur vierge
  donnaient deux propriétaires, et une invitation à usage unique pouvait ouvrir deux comptes.
- **Une vingtaine de routes lisaient leur corps JSON sans limite de taille.**
- **N'importe quel compte pouvait faire joindre au serveur l'adresse de son choix** en la déclarant
  comme serveur Emby. Le message d'erreur renvoyé servait alors à sonder le réseau interne.

## Décision

- **La table `sessions` ne garde que l'empreinte SHA-256 du jeton.** Sans sel ni dérivation lente :
  le jeton contient déjà 256 bits d'aléa. La migration 13 hache les jetons existants, donc les
  appareils déjà connectés le restent. Les tables d'appairage et de demandes d'accès gardent le
  jeton en clair jusqu'à ce que l'appareil vienne le chercher, puisqu'elles doivent le lui remettre.
- **Un seau à jetons par adresse** protège la connexion, l'inscription, l'appairage, les demandes
  d'accès et la liaison de serveurs. **Un second seau par nom de compte** protège contre les essais
  répartis sur plusieurs adresses. Il est assez large pour qu'un inconnu ne puisse pas bloquer le
  vrai titulaire en quelques essais.
- **L'adresse retenue est celle de la connexion.** Si cette adresse est locale (un proxy inverse),
  c'est la dernière entrée de `X-Forwarded-For`, celle que le proxy a ajoutée, et pas la première,
  que le client écrit lui-même.
- **Une connexion sur un compte inexistant compare quand même un hash bcrypt**, pour prendre le même
  temps qu'un mauvais mot de passe.
- **Le compte et ce qui l'autorise s'écrivent dans une même transaction.** Pour le propriétaire :
  la table doit être vide au moment de l'écriture. Pour un invité : l'invitation doit encore être
  inutilisée au moment où on la consomme.
- **Tout corps de requête est limité à 8 Mio**, sauf l'envoi d'installateurs, que sa route limite
  elle-même.
- **Les appels vers une URL saisie par un utilisateur refusent les adresses link-local, multicast
  et non spécifiées.** Cela couvre le service de métadonnées des hébergeurs cloud. Le réseau local
  et la machine elle-même restent permis, puisque c'est là que tourne d'ordinaire un serveur Emby.
  Le détail d'une erreur réseau ne va plus que dans le journal.
- **La durée d'un média mesurée par un client n'est enregistrée que si ce client détient un ticket
  de lecture pour ce média.**

## Conséquences

- **Le hachage est irréversible.** Revenir en arrière demanderait de reconnecter tous les appareils.
- **Les compteurs vivent en mémoire.** Un redémarrage les remet à zéro, ce qui ne rend que quelques
  essais à un attaquant.
- **Un client du réseau local qui se connecte directement peut encore forger `X-Forwarded-For`**
  et échapper à la limite par adresse. La limite par compte le rattrape pour les mots de passe.
- Les applications n'ont rien à changer : le jeton qu'elles présentent reste le même, et un refus
  pour trop d'essais leur arrive en 429 avec `Retry-After`.
