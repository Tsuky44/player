# ADR-0079 — Durcissement après l'audit de sécurité d'octobre 2026

- **Statut :** accepté. Testé en Go (`server/handlers/security_hardening_test.go`,
  `server/clientip/clientip_test.go`, `server/streaming/base_url_test.go`,
  `server/webui/webui_test.go`) et en Dart (`app/test/macos_update_signature_test.dart`,
  `app/test/external_url_policy_test.dart`). La mise à jour macOS signée n'a pas encore été vue
  de bout en bout sur un vrai Mac : le schéma a été vérifié avec une clé jetable.
- **Date :** 2026-10-22
- **Portée :** la publication d'installeurs (`server/handlers/downloads.go`, page Applications
  de l'app), la mise à jour macOS (`app/lib/services/macos_update_signature_io.dart`,
  `scripts/sign-macos-update.sh`, `.github/workflows/release.yml`), l'ouverture de liens
  (`app/lib/utils/external_url_*.dart`), les appels sortants (`server/handlers/federation.go`),
  l'adresse du client (`server/clientip`), les droits d'administration
  (`server/handlers/admin_reach.go`), le premier compte (`server/handlers/setup_code.go`), les
  mots de passe, les jetons de l'app (`app/lib/services/server_registry.dart`), le webui et TLS.

## Contexte

Un audit a classé les failles par gravité. Les plus graves étaient côté client : un serveur
malveillant (ou un administrateur, ou quiconque lisait le trafic HTTP) pouvait faire exécuter du
code sur les Mac par la mise à jour automatique, et sur les postes Windows par un `&` glissé dans
un lien ouvert avec `cmd /c start`. Venaient ensuite un appel sortant non gardé (liaison de
serveurs), une limite de débit contournable par `X-Forwarded-For`, un administrateur des comptes
capable de se donner tous les droits, un serveur neuf que le premier venu pouvait prendre, et des
défauts plus légers.

La contrainte : ne casser aucune fonctionnalité de l'app.

## Décision

1. **Plus d'envoi ni de suppression d'installeur par l'API.** `POST` et `DELETE /api/downloads`
   disparaissent avec leur écran. Les installeurs viennent de la Release (ADR-0062) ou du
   dossier, posés à la main sur la machine. Le corps de toute requête est de nouveau borné.
2. **La mise à jour macOS exige une signature.** L'app n'est pas signée par Apple, donc
   `codesign` ne prouve rien. La CI signe l'empreinte du bundle `Onyx.app` et sa version avec la
   clé des mises à jour Windows (ADR-0030) et range la signature dans le DMG
   (`.onyx-update.sig`). L'app la vérifie avec `/usr/bin/openssl` avant de remplacer quoi que ce
   soit. Un DMG non signé est refusé : il s'installe alors à la main.
3. **Un lien n'est ouvert que s'il est un lien web absolu** (`http`/`https`, sans espace ni
   caractère de contrôle). Sous Windows, `rundll32 url.dll,FileProtocolHandler` remplace
   `cmd /c start`. Le nom et le chemin d'un installeur venus du serveur sont bornés.
4. **La liaison de serveurs passe par le garde de `httpx.UserDirected`** (déjà celui d'Emby) :
   ni métadonnées cloud ni adresses réservées, et l'erreur de transport reste dans le journal.
   Le réseau local reste permis : c'est là que vivent d'ordinaire Emby et l'autre serveur.
5. **L'adresse du client passe par `clientip`** : `X-Forwarded-For` est lu de droite à gauche
   tant que le saut est un proxy de confiance. Par défaut, toute adresse locale l'est, pour qu'un
   proxy dans le réseau Docker marche sans réglage ; `TRUSTED_PROXIES` resserre. Chaque proxy
   est en plus borné à dix fois la limite d'un client, ce qui ferme le contournement même avec
   le défaut. `X-Forwarded-Proto` n'est cru que d'un proxy, et seulement `http` ou `https`.
6. **Un administrateur n'accorde ou ne retire que des droits qu'il a**, et n'agit (droits, mot
   de passe, second facteur, appareils, suppression) que sur un compte dont il tient chaque
   droit. Le propriétaire n'a pas de borne.
7. **Le premier compte, depuis Internet, exige un code d'installation** écrit dans le journal
   du serveur au démarrage. Depuis la machine ou le réseau local, rien ne change. Le code
   voyage dans `invite_token` ; l'app le demande dans le champ de l'invitation.
8. **Un mot de passe choisi fait au moins 8 caractères.** La connexion n'y est pas soumise : un
   compte créé avec l'ancienne limite garde son mot de passe.
9. **Le jeton de session vit dans le coffre du système**, les préférences ne servant plus que
   de repli quand le coffre refuse d'écrire.
10. **Le webui refuse d'être affiché dans un cadre** (`frame-ancestors 'none'`,
    `X-Frame-Options`). La politique ne borne pas les scripts : CanvasKit en a besoin.
11. **TLS natif optionnel** (`TLS_CERT_FILE`, `TLS_KEY_FILE`).

## Écarté

- **Interdire le réseau local aux appels sortants** : Emby et les serveurs liés y sont
  d'ordinaire ; la fonctionnalité aurait cessé de marcher.
- **Refuser le HTTP en clair dans l'app** : un serveur de la maison se joint par
  `http://192.168…` ; seul un certificat local le permettrait. TLS reste au choix de
  l'administrateur, et la mise à jour macOS ne dépend plus du transport.
- **Faire tourner le conteneur sans root par défaut** : les dossiers de médias d'une
  installation existante n'ont aucune raison d'être lisibles par un autre compte ; la mise à
  jour les aurait rendus invisibles. `PUID` reste le moyen, documenté.
- **Chiffrer les secrets en base** (TOTP, secrets des serveurs liés, jeton Emby) : la clé
  vivrait à côté de la base, sur le même disque ; la protection serait de façade.
- **Sortir le ticket de lecture de l'URL** : les lecteurs natifs ne portent pas d'en-tête ; le
  ticket vit 15 minutes, ne sert qu'un média et part sans `Referer`.

## Conséquences

- Les Mac installés avant cette version se mettent à jour une dernière fois sans vérification ;
  ensuite, sans `ONYX_UPDATE_SIGNING_KEY` en CI, ils refusent la mise à jour automatique.
- Un administrateur qui publiait un installeur depuis l'app le pose désormais dans le dossier.
- Derrière un proxy inverse, l'inscription du propriétaire demande le code du journal.
- Un administrateur qui n'a que `manage_users` ne gère plus les comptes mieux dotés que lui.
