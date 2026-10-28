# Contrat Onyx ↔ OnyxHub

Les formats qu'Onyx et OnyxHub s'échangent (ADR-0075). Chaque fichier est un exemple réel
d'un message, relu par les tests **des deux** dépôts : un format qui change d'un seul côté
fait échouer l'autre.

| Fichier | Qui l'écrit → qui le lit | Route |
|---|---|---|
| `request.json` | app Onyx → OnyxHub (relayé par Onyx) | `POST {OnyxHub}/api/request` |
| `availability.json` | OnyxHub → Onyx | `GET {OnyxHub}/api/media/availability/:id` |
| `availability_batch_request.json` | Onyx → OnyxHub | `POST {OnyxHub}/api/media/availability` |
| `availability_batch.json` | OnyxHub → Onyx | réponse de la précédente |
| `integration_ping.json` | OnyxHub → Onyx | `GET {OnyxHub}/api/integration/ping` |
| `my_requests.json` | OnyxHub → app Onyx (relayé par Onyx) | `GET {OnyxHub}/api/request` |
| `request_feed.json` | OnyxHub → app Onyx (relayé par Onyx) | `GET {OnyxHub}/api/request/feed` |
| `imported.json` | OnyxHub → Onyx | `POST {Onyx}/api/integrations/onyxhub/imported` |
| `library_tmdb_index.json` | Onyx → OnyxHub | `GET {Onyx}/api/library/tmdb-index` |
| `library_show_episodes.json` | Onyx → OnyxHub | `GET {Onyx}/api/library/shows/:tmdb/episodes` |
| `mediahub_link_test.json` | Onyx → OnyxHub et app Onyx | `POST {Onyx}/api/settings/mediahub/test` |

En-têtes de chaque appel d'Onyx vers OnyxHub : `Authorization: Bearer <clé d'intégration>`,
`X-Player-Username` et, depuis l'ADR-0075, `X-Player-Id`.

OnyxHub garde une copie de ces fichiers (et de `contract/ping.json`, `watch_list.json`,
`watch_lists.json`, qu'il lit aussi) dans `tests/contract/onyx/`. Son test de contrat compare
la copie à ce dossier quand le dépôt d'Onyx est à côté du sien.
