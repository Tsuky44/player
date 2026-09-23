---
name: onyx-engineering
description: Standards d'ingénierie d'Onyx (serveur Go + app Flutter). À charger avant d'écrire, modifier, refactorer ou relire du code de ce dépôt — route, handler, SQL, migration, indexeur, streaming, provider, service, lecteur, écran ou widget.
---

# Onyx — ingénierie

Onyx, c'est un serveur média privé en Go + SQLite (`server/`) et un client Flutter (`app/`) qui tourne sur Android, Android TV, iOS, tvOS, macOS, Windows et le web. Le Direct Play passe d'abord, le transcodage sert de repli.

La barre : chaque changement laisse le code plus *deep* qu'il ne l'était. Une interface étroite, la logique derrière un seul *seam*, et une preuve (test ou *guard test*) que le comportement tient.

Pendant la tâche, suis la règle « travail silencieux, récap final » du `CLAUDE.md` à la racine.

## Étapes

1. **Orienter.** Lis les ADR de la zone dans `docs/adr/` (titres en français : grep par concept ou par nom de fichier, car elles citent les chemins qu'elles couvrent). Lis le fichier touché et ses voisins pour trouver le *seam* existant, c'est-à-dire le type, le provider ou la fonction qui porte déjà cette responsabilité.
   Cette étape est finie quand tu peux nommer les ADR qui contraignent le changement (ou affirmer qu'aucune ne le fait) et le seam où il va.
2. **Charger la référence de la branche**, une ou plusieurs :
   - Serveur Go (route, handler, SQL, migration, indexeur, streaming, tâche de fond) → [server.md](server.md)
   - Logique de l'app (provider, service, `ApiClient`, lecteur, téléchargements, multi-serveur, code propre à une plateforme) → [app.md](app.md)
   - Interface (écran, widget, thème, animation, focus TV, responsive) → [ui.md](ui.md)

   Un changement de contrat d'API touche les deux côtés : charge server.md et app.md, puis fais évoluer le modèle Go et le modèle Dart dans le même changement.
3. **Implémenter** en suivant la référence et les règles transverses ci-dessous.
4. **Vérifier.** La CI (`.github/workflows/ci.yml`) lance `go vet`, `go test -race`, `flutter analyze` et `flutter test`, et bloque la publication d'une image ou d'une version s'ils sont rouges. Elle ne passe qu'après le push : vérifie en local avant.
   - Serveur, dans `server/` : `gofmt -l .` ne doit rien afficher, puis `go vet ./...` et `go test ./...`.
   - App, dans `app/` : `flutter analyze` sans nouveau problème dans les fichiers touchés, puis `flutter test` (d'abord le fichier ciblé, ensuite la suite complète).
   - UI : regarde l'écran tourner (skill `run`) en largeur téléphone et en largeur desktop, et au D-pad si l'écran est atteignable sur TV.

   Cette étape est finie quand chaque commande pertinente est verte et que tu as lu sa sortie. Un échec qui existait avant ton changement se signale, il ne se contourne pas.
5. **Laisser la trace.**
   - Pour une décision difficile à défaire, surprenante, ou qui s'écarte d'une ADR : écris une nouvelle ADR `docs/adr/00NN-titre-en-kebab.md`, en français, au format des existantes (Statut, Date, Portée, Contexte, Décision, Conséquences). Un écart à une ADR existante se dit explicitement : *« Contredit l'ADR-00NN parce que… »*.
   - Le nouveau comportement est épinglé par un test nommé d'après la règle qu'il protège.

## Règles transverses

### Modules *deep*, *seams*, taille des fichiers

- Une nouvelle responsabilité va dans un nouveau fichier ou un nouveau type, avec une interface étroite. L'appelant ne voit pas les détails.
- Les fichiers-dieux sont `player_screen.dart` (~3 400 lignes), `use_player_controller.dart` (~2 200), `api_client.dart` (~1 200 ; ses points d'accès par domaine vont dans `services/api/`, en mixins `part of`, surchargeables par les doublures de test), `control_chrome.dart`, `models.dart`, `emby_sync.go` et `federation.go`. Pour y ajouter du code, extrais d'abord dans son propre fichier (widget, hook, service, sous-package) le morceau que tu touches, puis modifie-le là. Ton changement ne fait passer aucun fichier au-dessus de 800 lignes.
- Chaque signification a une seule source de vérité (constante, token, helper). Avant d'écrire un helper, cherche s'il existe déjà : `sqlPlaceholders`, `scanSQLiteTime`, `Responsive`, `AppNetworkImage`, `AppMotion`…
- Le serveur décide (permissions, progression, « vu », droits de lecture) et l'app affiche. Une règle métier côté client n'existe que pour l'UI optimiste, et la réponse du serveur la réconcilie.

### *Guard tests* plutôt que règles écrites

Une convention qui doit tenir dans tout le dépôt devient un test qui scanne le code, sur le modèle de `app/test/no_bare_text_field_test.dart` : une liste blanche courte, une justification par entrée, et un message d'échec qui explique le *pourquoi*. Chaque nouvelle convention arrive avec son guard test.

### Commentaires

Le dépôt commente le *pourquoi* : la panne observée, la mesure, l'alternative écartée, l'ADR (`Voir ADR-0013`). Garde ce registre et la langue du fichier. Les nouveaux commentaires et les ADR s'écrivent en français. Un commentaire qui paraphrase le code se supprime.

### Erreurs

Chaque erreur est traitée, remontée avec son contexte (`fmt.Errorf("…: %w", err)`) ou journalisée. Côté client, un échec se dégrade de façon visible (état d'erreur, données en cache) et l'écran ne reste jamais figé.

### Budgets

- Le serveur reste léger (objectif < 20 Mo de RAM au repos), SQLite tourne en WAL, et il n'y a pas de CGO (`modernc.org/sqlite`).
- L'app démarre hors ligne (polices embarquées, ADR-0025) et reste fluide sous Windows et sur TV.
- Une nouvelle dépendance Flutter reçoit un commentaire dans `pubspec.yaml` qui dit pourquoi elle est là et ce qui la bloque à sa version, comme les dépendances existantes. Vérifie aussi sa prise en charge sur chaque cible : tvOS n'a pas media_kit (ADR-0028), et le web passe par des imports conditionnels.

### Portée

Change ce que la tâche demande, plus le nettoyage des lignes que tu touches (un token à la place d'une couleur brute, un helper à la place d'un doublon). Un nettoyage plus large se propose à part.
