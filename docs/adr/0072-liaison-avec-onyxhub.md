# ADR-0072 — La liaison avec OnyxHub se teste depuis le serveur, et le catalogue lit ses disponibilités par page

- **Statut :** accepté
- **Date :** 2026-10-20
- **Portée :** le serveur (`server/handlers/mediahub_link.go`, `server/handlers/mediahub_batch.go`,
  `enrichCatalogAvailability` dans `server/handlers/tmdb_requests.go`, la route
  `POST /api/settings/mediahub/test` dans `server/main.go`, capacité `mediahub_link_test` dans
  `server/handlers/ping.go`, `contract/ping.json`) et l'app
  (`app/lib/screens/settings/pages/integrations_page.dart`, `testMediaHubLink` dans
  `app/lib/services/api/library_admin.dart`). Côté OnyxHub : son ADR-0009.

## Contexte

OnyxHub remplace MediaHub et en garde les deux routes (`POST /api/request`,
`GET /api/media/availability/:id`). Deux défauts restaient :

- Une adresse ou une clé fausse dans « Adresse MediaHub » ne se remarquait qu'à la première
  demande refusée. L'app ne peut pas tester elle-même : elle n'est pas sur le réseau du
  serveur, et c'est le serveur qui doit joindre OnyxHub (un nom Docker marche pour lui, pas
  pour un téléphone, et inversement).
- Le catalogue de demandes appelait la disponibilité une fois par carte : vingt appels par page,
  huit à la fois, alors qu'OnyxHub sait répondre pour toute la page à partir d'un seul index.

## Décision

- `POST /api/settings/mediahub/test` (`manage_settings`) fait appeler au serveur
  `GET /api/integration/ping` d'OnyxHub avec la clé, qui n'y répond 200 qu'à la bonne clé.
  Le résultat est toujours un `200 { ok, message }` : un test raté n'est pas une erreur du
  serveur Onyx. Un MediaHub, qui n'a pas de ping, est reconnu à sa route de disponibilité.
  L'app affiche « Tester » à côté d'« Enregistrer » et teste les valeurs du formulaire avant
  qu'elles soient enregistrées. Un serveur plus ancien se reconnaît à l'absence de la capacité
  `mediahub_link_test`.
- `enrichCatalogAvailability` envoie la page entière à `POST /api/media/availability`. Un
  `404`/`405` veut dire que l'hôte ne connaît pas la route (MediaHub, OnyxHub ancien) : on
  retombe sur l'appel par carte, et on ne retente le lot qu'après 10 minutes, pour suivre une
  mise à jour d'OnyxHub sans perdre un appel à chaque page.
- Les réglages gardent leurs noms `mediahub_url` / `mediahub_api_key` : les installations
  existantes les ont déjà, et OnyxHub les écrit sous ces noms.

## Conséquences

- La page Demandes de l'app coûte un appel vers OnyxHub au lieu de vingt.
- Le test fait appeler au serveur une adresse saisie : il est réservé à `manage_settings`,
  comme l'écriture de cette adresse.
- MediaHub reste servi tel quel, avec l'appel par carte.
