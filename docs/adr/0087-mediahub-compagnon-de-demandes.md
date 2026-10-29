# ADR-0087 — MediaHub, compagnon de demandes d'Onyx par son API v1

- **Statut :** accepté
- **Date :** 2026-10-29
- **Portée :** le package `server/mediahub/`, `server/handlers/mediahub*.go`, les routes
  `/api/requests/*` et `/api/integrations/mediahub/events`, `contract/mediahub/`, et côté app
  `models/my_request.dart`, `services/api/my_requests.dart`, `screens/requests/`. Prolonge les
  ADR-0072 à 0077 (OnyxHub) sans les retirer.

## Contexte

OnyxHub, le compagnon de demandes écrit pour Onyx, est abandonné : MediaHub devient le seul. MediaHub
publie une API d'intégration versionnée (`/api/integrations/player/v1`, son
`docs/player-integration/v1/`) qui couvre tout ce qu'Onyx lisait chez OnyxHub, et plus : les droits
du compte, les demandes refusées et leur motif, la raison d'attente avec la date de sortie, la
modération, et des évènements signés poussés vers Onyx.

Les deux ne parlent pas la même langue. MediaHub écrit une ligne de demande par saison, là où OnyxHub
rendait un lot par geste ; il ne donne pas de progression ; il retrouve un compte par son nom
(`X-Player-Username`) et ignore `X-Player-Id`. Des installations ont encore OnyxHub.

## Décision

- **Un client, deux dialectes.** Le package `server/mediahub` est le seul à parler au compagnon.
  `Client.Dialect` sonde `GET {url}/api/integrations/player/v1/ping` : `200` ou `401`/`403` disent
  MediaHub v1, `404` dit OnyxHub. Le dialecte se retient 10 minutes par adresse (15 s quand
  l'adresse est muette), et le test de liaison le note. Les handlers ne voient que des méthodes
  (`Availability`, `AvailabilityBatch`, `CreateRequest`, `Requests`, `Feed`, `Moderate`, `Access`) et
  des erreurs (`StatusError`, `ErrNotConfigured`, `ErrUnreachable`, `ErrUnsupported`).
- **Onyx rend son propre format à l'app.** `GET /api/requests/mine` ne relaie plus la réponse du
  compagnon : il rend des *lots* (`mediahub.Lot`, épinglé par `contract/requests_mine.json`). Les
  lignes d'une même série et d'un même compte font un lot, avec `requestIds`, `seasonStatuses`, la
  raison d'attente et le motif de refus. Le statut d'un lot suit sa saison la plus en retard ; une
  saison disponible le rend `partial`, toutes `available`, toutes refusées `declined`. Les lots
  d'OnyxHub, déjà un par geste, se lisent dans la même struct.
- **Le flux reste celui de l'ADR-0077.** Les saisons consécutives d'un même geste font une entrée ;
  Onyx écarte lui-même les demandes du compte qui lit (OnyxHub le faisait chez lui).
- **Droits.** MediaHub juge chaque droit d'après le rôle du compte de même nom. Onyx expose ce rôle
  (`GET /api/requests/access`) pour que l'app n'affiche que ce qui est permis, et exige en plus
  `manage_settings` pour lire toutes les demandes et modérer : le nom est le seul lien entre les
  deux comptes tant que la connexion avec le compte Onyx (phase 4) n'existe pas, et un nom choisi à
  l'inscription ne doit pas suffire à modérer.
- **Évènements.** `POST /api/integrations/mediahub/events` remplace, pour MediaHub,
  `/api/integrations/onyxhub/imported` (ADR-0074). La clé d'intégration dit qui appelle ; la
  signature HMAC-SHA256 du corps brut, avec la même clé, dit que le corps n'a pas changé en route.
  Une livraison n'est appliquée qu'une fois (une heure de mémoire). `media.imported` oublie le statut
  en cache et avance le moniteur ; les évènements de demande oublient le statut en cache. Un
  évènement inconnu est accepté (`202`) sans effet, un corps illisible refusé en `400` pour que
  MediaHub ne le réessaie pas.
- **Contrat.** `contract/mediahub/` est une copie des exemples de MediaHub, relue par
  `mediahub_contract_test.go`.

## Conséquences

- Un OnyxHub continue de marcher sans rien régler. `ErrUnsupported` (HTTP `501`) dit à l'app qu'une
  fonction nouvelle (toutes les demandes, modération) n'existe pas chez lui.
- La progression d'un téléchargement disparaît avec MediaHub v1 (`progress` toujours `null`) ;
  l'app la montre encore si elle arrive.
- Le premier appel de chaque période de 10 minutes paie un ping de plus.
- Un compte Onyx sans compte MediaHub de même nom peut demander (MediaHub lui prête les droits d'un
  compte sans rôle) mais ne retrouve pas ses demandes ; le test de liaison le signale pour le compte
  de l'administrateur.
- Ce qui reste propre à OnyxHub et pourra partir quand il sera retiré : les branches `DialectOnyxHub`
  du package, `probeOnyxHub`, `onyxhub_import.go` et sa route, `contract/onyxhub/` et ses tests, la
  capacité `onyxhub_import_signal`.
