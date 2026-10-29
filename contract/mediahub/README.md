# Contrat Onyx ↔ MediaHub (API d'intégration v1)

Les messages qu'Onyx et MediaHub s'échangent (ADR-0087). Ces fichiers sont une copie des exemples
de MediaHub (`docs/player-integration/v1/examples/` dans son dépôt), relue par
`server/handlers/mediahub_contract_test.go` : ce que MediaHub écrit doit se lire sans rien perdre,
et ce qu'Onyx envoie doit valoir le fichier. Un format qui change se change des deux côtés.

Base : `{MediaHub}/api/integrations/player/v1`.

| Fichier | Qui l'écrit → qui le lit | Route |
|---|---|---|
| `ping.json` | MediaHub → Onyx | `GET /ping` (test de liaison, dialecte, droits du compte) |
| `availability.json` | MediaHub → Onyx | `GET /availability/:tmdbId?type=` |
| `availability_batch_request.json` | Onyx → MediaHub | `POST /availability` |
| `availability_batch.json` | MediaHub → Onyx | réponse de la précédente (écrit par Onyx d'après la doc de MediaHub) |
| `request_create.json` | app Onyx → MediaHub (relayé par Onyx) | `POST /requests` |
| `request_create_response.json` | MediaHub → app Onyx (relayé) | réponse de la précédente |
| `requests_list.json` | MediaHub → Onyx | `GET /requests?scope=mine\|all` |
| `request_detail.json` | MediaHub → Onyx | `GET /requests/:id`, réponse de `PATCH /requests/:id` |
| `request_moderate.json` | Onyx → MediaHub | `PATCH /requests/:id` |
| `request_feed.json` | MediaHub → Onyx | `GET /requests/feed?after=` |
| `event_*.json` | MediaHub → Onyx | `POST {Onyx}/api/integrations/mediahub/events` |

En-têtes de chaque appel d'Onyx : `Authorization: Bearer <clé d'intégration>` et, au nom d'un
compte, `X-Player-Username` (et `X-Player-Id`, que MediaHub ignore). Chaque évènement porte en plus
`X-MediaHub-Event`, `X-MediaHub-Delivery` et `X-MediaHub-Signature: sha256=<HMAC-SHA256 du corps>`.

Ce qu'Onyx rend à son app à partir de ces messages (les lots de demandes, le flux, les droits) est
épinglé à part, dans `contract/requests_*.json`, par `TestAPIContract`.
