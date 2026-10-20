# ADR-0075 — Le contrat avec OnyxHub tient dans contract/onyxhub/, et le compte voyage par son identifiant

- **Statut :** accepté
- **Date :** 2026-10-20
- **Portée :** `contract/onyxhub/`, `server/handlers/onyxhub_contract_test.go`,
  `app/test/api_contract_test.dart`, `proxyMediaHub` dans `server/handlers/mediahub.go`,
  les libellés de `app/lib/screens/settings/pages/integrations_page.dart`. Côté OnyxHub : son
  ADR-0012.

## Contexte

Les ADR-0072 à 0074 ont ajouté des routes entre Onyx et OnyxHub. Leurs formats étaient écrits
à la main de chaque côté, et rien ne les tenait ensemble : `contract/` (ADR-0051) ne couvre
que ce que l'app lit du serveur. Trois restes de MediaHub traînaient aussi :

- `MediaHubCatalog` et `MediaHubDetails`, branchés sur aucune route ;
- « MediaHub » dans les réglages de l'app et les messages d'erreur ;
- un compte transmis par son seul nom, si bien qu'un compte renommé perdait ses demandes.

## Décision

- **`contract/onyxhub/`** garde un exemple réel de chaque message échangé, dans les deux sens.
  Son `README.md` dit qui écrit et qui lit chaque fichier.
  - `onyxhub_contract_test.go` fait passer ces fichiers par le vrai code d'Onyx : le lot de
    disponibilités qu'il envoie, ce qu'il lit des réponses, le test de liaison, l'annonce
    d'import, l'index TMDB et la demande relayée.
  - `api_contract_test.dart` relit « Mes demandes » et le test de liaison avec les modèles de
    l'app.
  - OnyxHub en garde une copie, que son propre test compare à ce dossier dès que les deux
    dépôts sont côte à côte. Il y ajoute `ping.json`, `watch_list.json` et
    `watch_lists.json`, qu'il lit aussi.
- **`X-Player-Id`** accompagne `X-Player-Username` sur chaque appel relayé vers OnyxHub.
- **Les libellés parlent d'OnyxHub.** Les clés de réglage `mediahub_url` et `mediahub_api_key`
  ne changent pas : les installations existantes les ont déjà, et OnyxHub les écrit sous
  ces noms (ADR-0072). Un ancien MediaHub reste accepté.
- Les deux handlers morts sont supprimés.

## Conséquences

- Changer un format échangé avec OnyxHub, c'est changer le fichier de `contract/onyxhub/`,
  puis faire passer les tests d'Onyx et ceux d'OnyxHub.
- MediaHub ignore `X-Player-Id`. OnyxHub s'en sert pour suivre un compte renommé.
