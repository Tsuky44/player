# Contrat Onyx ↔ MediaHub (API d'intégration v1)

Les messages qu'Onyx et MediaHub s'échangent (ADR-0089). Ces fichiers sont une copie des exemples
de MediaHub (`docs/player-integration/v1/examples/` dans son dépôt), relue par
`server/handlers/mediahub_contract_test.go` : ce que MediaHub écrit doit se lire sans rien perdre,
et ce qu'Onyx envoie doit valoir le fichier. Un format qui change se change des deux côtés.

Base : `{MediaHub}/api/integrations/player/v1`.

| Fichier | Qui l'écrit → qui le lit | Route |
|---|---|---|
| `ping.json` | MediaHub → Onyx | `GET /ping` (test de liaison, dialecte, droits du compte) |
| `availability.json` | MediaHub → Onyx | `GET /availability/:tmdbId?type=` |
| `availability_batch_request.json` | Onyx → MediaHub | `POST /availability` |
| `availability_batch.json` | MediaHub → Onyx | réponse de la précédente |
| `request_create.json` | app Onyx → MediaHub (relayé par Onyx) | `POST /requests` |
| `request_create_response.json` | MediaHub → app Onyx (relayé) | réponse de la précédente |
| `requests_list.json` | MediaHub → Onyx | `GET /requests?scope=mine\|all` |
| `request_detail.json` | MediaHub → Onyx | `GET /requests/:id`, réponse de `PATCH /requests/:id` |
| `request_moderate.json` | Onyx → MediaHub | `PATCH /requests/:id` |
| `request_feed.json` | MediaHub → Onyx | `GET /requests/feed?after=` |
| `event_*.json` | MediaHub → Onyx | `POST {Onyx}/api/integrations/mediahub/events` |

En-têtes de chaque appel d'Onyx : `Authorization: Bearer <clé d'intégration>` et, au nom d'un
compte, `X-Player-Username` et `X-Player-Id` (l'id stable du compte Onyx, ADR-0090). Chaque évènement porte en plus
`X-MediaHub-Event`, `X-MediaHub-Delivery` et `X-MediaHub-Signature: sha256=<HMAC-SHA256 du corps>`.

Ce qu'Onyx rend à son app à partir de ces messages (les lots de demandes, le flux, les droits) est
épinglé à part, dans `contract/requests_*.json`, par `TestAPIContract`.

## Se connecter à MediaHub avec son compte Onyx (ADR-0090)

Ces fichiers-là sont écrits par Onyx et relus par
`server/handlers/mediahub_sso_test.go` (`TestMediaHubLoginContract`, régénérés avec
`ONYX_UPDATE_CONTRACT=1`). Les valeurs aléatoires (jeton, étape, code) y sont fixées. Le compte est
désigné par `user.id`, jamais réutilisé ; `username` ne change pas et sert de nom affiché.

| Fichier | Qui l'écrit → qui le lit | Route (chez Onyx) |
|---|---|---|
| `onyx_login.json` | Onyx → MediaHub | `POST /api/auth/login` `{username,password}` → `200` |
| `onyx_login_otp.json` | Onyx → MediaHub | même route, `401` quand un code est attendu (clé `otp`) ; suite par `POST /api/auth/otp/login` `{challenge,code}`, qui rend `onyx_login.json` |
| `onyx_me.json` | Onyx → MediaHub | `GET /api/auth/me` (Bearer session) → `200` |
| `onyx_sso_redeem_request.json` | MediaHub → Onyx | `POST /api/integrations/mediahub/sso/redeem` (Bearer clé d'intégration) |
| `onyx_sso_redeem.json` | Onyx → MediaHub | réponse `200` de la précédente |

Erreurs : toujours `{"error": "…"}`. Login : `401` sans clé `otp` = mauvais identifiants, `429` +
`Retry-After`. Étape OTP : `401` « Code incorrect » (on peut redemander), `410` (on recommence au mot
de passe). Rachat : `401` mauvaise clé, `400` corps illisible, `410` code inconnu, expiré, déjà
utilisé ou compte supprimé.

Le code naît dans l'app Onyx : `POST /api/integrations/mediahub/sso` (session) rend
`{"url":"{mediahub_url}/api/auth/onyx/sso?code=<64 hex>","expires_in":60}` (épinglé côté app par
`contract/mediahub_sso.json`). Le navigateur ouvre `url` ; MediaHub rachète le code, ouvre sa
session et redirige.
