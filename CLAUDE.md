## Communication : travail silencieux, récap final

Pendant une tâche, travaille en silence : enchaîne lectures, modifications et commandes sans commenter chaque action. Le seul message en cours de route est une question bloquante, c'est-à-dire une décision qui revient à l'utilisateur. Si l'utilisateur demande de détailler ce que tu fais, commente alors au fil de l'eau jusqu'à la fin de cette tâche.

À la fin, un seul **récap** court :
- **Fait** : ce qui a été implémenté, avec les fichiers clés en liens.
- **Vérifié** : les commandes lancées et leur résultat (vert/rouge).
- **À savoir** : les échecs, les étapes sautées, les décisions prises et ce qui reste à faire. Omets cette partie si elle est vide.

## Économie de tokens

- Pour trouver une fonction, un handler, un symbole ou la structure d'un fichier, utilise le skill `smart-explore` (AST) au lieu de lire le fichier entier.
- Pour une question d'architecture ou de relations entre fichiers, interroge d'abord le graphe `graphify-out/` (`/graphify query`) avant de relire le code.
- Ne lis jamais `app/build/`, `app/macos/build_xcode/`, `app/windows/flutter/ephemeral/`, `.claude/worktrees/`, `server/downloads/`, `server/data/`. Ces dossiers sont refusés dans `.claude/settings.json`.

## Agent skills

### Standards de code

Pour tout code de ce dépôt, charge le skill `onyx-engineering` (`.claude/skills/onyx-engineering/`).

### Issue tracker

Issues and PRDs live as GitHub issues in this repo. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
