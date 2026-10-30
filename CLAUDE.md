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

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
