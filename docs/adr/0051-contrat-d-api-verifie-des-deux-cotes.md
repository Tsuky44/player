# ADR-0051 — Un contrat d'API vérifié des deux côtés

- **Statut :** accepté. Go et Dart testés ; l'image arm64 a été construite et lancée en local sous
  émulation. **Aucune image multi-architecture n'a encore été publiée par la CI.**
- **Date :** 2026-10-08
- **Portée :** `contract/`, `server/handlers/contract_test.go`, `app/test/api_contract_test.dart`,
  `server/handlers/responses.go`, `server/handlers/ping.go`, `server/buildinfo/`,
  `app/lib/models/server_capabilities.dart`, `server/Dockerfile`, `.github/workflows/ci.yml`,
  `.github/workflows/server.yml`, `.github/dependabot.yml`, `app/analysis_options.yaml`.

## Contexte

Le modèle Go et le modèle Dart d'une même réponse sont écrits à la main, de chaque côté, et rien ne
les tenait ensemble. Une quarantaine de réponses étaient même des `map[string]interface{}` écrites à
l'endroit de la réponse : aucune liste de leurs clés n'existait ailleurs que dans le code qui les
lisait. Renommer une clé passait tous les tests du serveur, et l'app lisait `null` en silence.

L'app, elle, ne savait pas quel serveur elle avait en face. La médiathèque peut être servie par
plusieurs serveurs de versions différentes (ADR-0013), et elle devinait : une route qui répond 404,
une réponse rendue trop vite pour avoir été tenue.

## Décision

1. **Une réponse JSON est une struct.** Les formes sans domaine vivent dans `responses.go`. Garde :
   `TestNoUntypedJSONResponses`. Aucun champ n'a reçu d'`omitempty` au passage : ce qui part sur le
   réseau n'a pas changé.
2. **`contract/` est le contrat.** Un fichier par réponse, tous champs remplis par réflexion.
   `TestAPIContract` (Go) échoue dès que le serveur écrirait autre chose ;
   `api_contract_test.dart` relit les mêmes fichiers avec les `fromJson` de l'app. Changer une
   réponse, c'est régénérer le fichier (`ONYX_UPDATE_CONTRACT=1`) puis faire passer le test Dart.
3. **`GET /api/ping` annonce `version` et `capabilities`.** Chaque comportement que l'app doit
   pouvoir distinguer reçoit un nom dans `ping.go`, ajouté le jour où le serveur l'acquiert et
   jamais retiré. L'app les lit dans `ServerCapabilities`.
4. **La CI ajoute `staticcheck` et `govulncheck`** au serveur, huit règles d'analyse à l'app, et
   Dependabot propose les mises à jour chaque semaine. L'image est publiée en **amd64 et arm64**.

## Alternatives écartées

- **Générer les modèles Dart depuis le Go** (OpenAPI, protobuf). C'est la réponse complète, mais
  elle remplace 1 700 lignes de `fromJson` écrites à la main, dont beaucoup portent une tolérance
  voulue aux anciens serveurs. Le contrat par fichiers attrape la même dérive sans rien réécrire.
- **Un numéro de version d'API** au lieu de capacités. Un numéro ordonne tout sur une ligne ; un
  serveur resté en arrière sur un point et à jour sur un autre ne s'y décrit pas.
- **Des règles d'analyse plus larges.** `unawaited_futures` lève 34 alertes à trier une par une ;
  `cancel_subscriptions`, `close_sinks` et `no_adjacent_strings_in_list` n'en levaient que de
  fausses ici. Une règle n'entre qu'à zéro alerte.

## Conséquences

- Le contrat couvre douze fichiers (dix réponses, dont deux avec leur forme vide), celles que l'app lit par un modèle typé. Les autres routes
  restent à y ajouter une à une.
- Les capacités sont annoncées et lues, mais **un seul endroit de l'app s'en sert** aujourd'hui
  (la lecture sans ticket des anciens serveurs). Le suivi de progression garde sa détection par le
  temps de réponse, qui marche aussi face à un serveur d'avant l'annonce.
- `docker-compose.prod.yml` épingle toujours `platform: linux/amd64`, et les scripts
  `publish-image.*` ne construisent qu'amd64 : une image publiée par eux redevient mono-architecture.
  Un hôte ARM n'aura l'image native qu'après une publication par la CI, et en retirant cette ligne.
- `staticcheck@latest` et `govulncheck@latest` suivent leurs dernières versions : une nouvelle
  règle peut faire échouer la CI sans changement du dépôt.
