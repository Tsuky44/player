# ADR-0080 — L'app passe en HTTPS dès que le serveur le parle

- **Statut :** accepté. Testé en Dart (`app/test/server_scheme_test.dart`) ; pas encore vu sur
  un vrai serveur passé en HTTPS.
- **Date :** 2026-10-23
- **Portée :** `app/lib/services/server_scheme.dart`, `ApiClient.setConnection` et
  `upgradeAccountsToHttps`, le lancement (`AuthProvider.tryAutoLogin`), les demandes d'accès et
  la connexion à un autre serveur (`services/api/account_admin.dart`), la portée des
  téléchargements hors ligne (`ServerAccount.sameAddress`).

## Contexte

L'ADR-0079 a rendu HTTPS possible sans proxy (`TLS_CERT_FILE`, `TLS_KEY_FILE`). Mais l'app
ajoutait `http://` à toute adresse tapée sans préfixe, et un compte enregistré en HTTP y
restait : un serveur passé en HTTPS devenait injoignable, ou continuait de recevoir mots de
passe et jetons en clair s'il parlait encore les deux.

## Décision

1. **Une adresse en `http://` ou sans préfixe est d'abord essayée en HTTPS** : `GET
   /api/ping` sur `https://` à la même adresse, deux secondes au plus. Une réponse Onyx valide,
   certificat vérifié, fait retenir HTTPS ; sinon l'adresse reste en HTTP.
2. **Au lancement, chaque compte enregistré en HTTP est sondé de même**, tous en parallèle. Un
   serveur qui répond en HTTPS voit ses comptes déplacés vers `https://`, jeton et profil
   compris (`ServerRegistry.updateUrl`) ; le compte actif reste le même.
3. **Jamais de retour en arrière automatique.** Une adresse en `https://` n'est pas rabattue sur
   HTTP quand HTTPS ne répond pas : un intermédiaire qui bloquerait HTTPS pourrait sinon faire
   repasser l'app en clair. L'utilisateur peut toujours retaper `http://`.
4. **Les téléchargements hors ligne suivent** : une entrée enregistrée en `http://` appartient
   au même serveur en `https://` (`ServerAccount.sameAddress`).

## Conséquences

- Un serveur en HTTPS est joint en HTTPS sans que personne ait à taper `https://`.
- Un certificat auto-signé est refusé comme pour toute requête : le serveur reste en HTTP.
  Il faut un certificat reconnu (Let's Encrypt, un proxy comme Caddy).
- Un serveur éteint ajoute au plus deux secondes au lancement, le temps du sondage HTTPS.
- Un serveur qui repasse de HTTPS à HTTP demande de retaper son adresse en `http://`.
