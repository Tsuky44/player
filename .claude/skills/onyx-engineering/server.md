# Serveur Go

Module `project-player/server`, Go 1.21, routeur `httprouter`, SQLite `modernc.org/sqlite`. Pour trouver l'endroit exact, pars des routes dans `server/main.go`.

## Découpage par package

| Package | Responsabilité |
|---|---|
| `handlers` | HTTP : décoder, autoriser, appeler, encoder. Contient aussi les stores en mémoire et les tâches de fond liés à une fonctionnalité. |
| `indexer` | Parcours des disques, identification, métadonnées, surveillance (`monitor.go`). |
| `streaming` | Sondage ffprobe, plan de lecture, HLS, échelle de transcodage, aperçus. |
| `subtitles`, `playbackauth`, `streamcache` | Sous-domaines profonds, chacun avec ses tests. |
| `database` | `InitDB`, PRAGMA, migrations. `database.DB` est global. |
| `models` | Structs partagées et JSON. `Permission*` vit ici. |
| `httpx` | Les seuls clients HTTP sortants. |
| `config`, `middleware`, `webui` | Réglages, gzip, SPA embarquée. |

Un handler reste **mince**. Dès que la logique dépasse « lire la requête → une requête SQL → répondre », elle part dans une fonction pure et testable (sur le modèle de `findResumeEpisodeRow`) ou dans le package du domaine. Pour une nouvelle fonctionnalité avec un état et un cycle de vie, crée un sous-package profond comme `playbackauth` plutôt qu'un fichier de plus dans `handlers`.

## Routes et autorisation

- Toutes les routes s'enregistrent dans `main.go`, groupées par domaine, avec un commentaire qui justifie le choix d'autorisation.
- Une route authentifiée prend un `AuthenticatedHandle` (`func(w, r, ps, userID int)`) enveloppé par `RequireAuth`, `RequirePermission(models.PermX, …)` ou `RequireAnyPermission`.
- On autorise par *capacité* (`PermManageLibrary`, `PermInviteUsers`…). Le test « propriétaire » est réservé aux actions de propriété et se fait dans le handler.
- Une route publique porte à côté d'elle un commentaire qui dit pourquoi elle l'est et ce qu'elle expose. `/api/auth/device/*` et `/api/auth/access/*` en sont le modèle : elles ne parlent qu'en codes aléatoires.
- Tout ce qui peut occuper le CPU (ffprobe, scan, détection) exige une permission.

## Requête et réponse

- Entrée JSON : `r.Body = http.MaxBytesReader(w, r.Body, limite)` puis `json.NewDecoder(r.Body).Decode(&req)`. Valide les champs et renvoie `400` sur une entrée invalide.
- Paramètres d'URL : `strconv.Atoi(ps.ByName("id"))`, avec `400` en cas d'échec.
- Sortie : `w.Header().Set("Content-Type", "application/json")` puis `json.NewEncoder(w).Encode(resp)`. La réponse est une struct de `models`, jamais une `map[string]interface{}` improvisée.
- Erreur : `http.Error(w, "message court", status)` avec le bon code (400, 401, 403, 404, 409, 500). Le détail interne part dans `log.Printf("<handler>: <étape>: %v", err)`, jamais dans la réponse.
- Codes d'état : `sql.ErrNoRows` donne `404`, un conflit d'unicité donne `409`.

## SQLite

- Requêtes paramétrées `?` uniquement. Une liste `IN` passe par `sqlPlaceholders(n)` et `fmt.Sprintf` sur une requête constante.
- Le `NULL` se gère en SQL avec `COALESCE` pour scanner dans des types Go simples (voir `episodeProgressQuery`). Les dates passent par `scanSQLiteTime`.
- Pas de N+1 : charge par lots (`loadEpisodesWithProgressForShows` a supprimé un aller-retour par série sur `/api/home`). Un index accompagne toute nouvelle colonne filtrée ou jointe.
- `defer rows.Close()`, puis vérifie `rows.Err()` après la boucle.
- Plusieurs écritures qui doivent réussir ensemble passent par une transaction (`database.DB.Begin()`, `defer tx.Rollback()`, `tx.Commit()`).
- **Migrations** : ajoute une entrée à la fin de `database/migrations.go` avec l'id suivant. Une migration publiée ne se modifie jamais, puisque les installations existantes l'ont déjà jouée.

## Clients sortants, tâches de fond, processus

- Appels sortants : `httpx.Fast`, `Standard`, `Catalog` ou `Long`, choisis selon l'échéance. Ils partagent un seul pool de connexions. Un nouveau client ne se crée que dans `httpx`.
- Tâche de fond : une fonction `RunX(ctx context.Context)` lancée depuis `main.go` avec `playbackContext`, qui rend la main sur `ctx.Done()`. Les nettoyages périodiques suivent le modèle des *reapers* existants.
- Un état partagé vit dans un petit store (struct + `sync.Mutex` + méthodes), avec un constructeur de test (`newTestWatchPartyStore`).
- ffmpeg/ffprobe passent par `streaming`. Tout processus lancé est lié à un `context` et tué à l'annulation. Les travaux secondaires (aperçus) tournent en priorité basse.
- Direct Play d'abord. Le transcodage suit l'échelle de débits (ADR-0022) et l'encodeur matériel reste optionnel (ADR-0023).

## Tests

- Le test vit à côté du code, dans le même package (`xxx_test.go`).
- Les tests qui touchent la base créent une vraie base avec `database.InitDB(filepath.Join(t.TempDir(), "test.db"))` pour exercer les migrations, puis referment avec `t.Cleanup`. Pas de `t.Parallel()` là-dessus, car `database.DB` est global.
- Les helpers de semis prennent `t.Helper()` et échouent avec `t.Fatalf("insert …: %v", err)`.
- Pour tester un handler, appelle-le directement avec `httptest.NewRecorder()`, `httptest.NewRequest(…)`, `nil` et le `userID`, puis décode la réponse.
- Les parseurs et règles pures (titres, SxxExx, qualité, plan) se testent en tables : une ligne par cas réel rencontré, et chaque bug corrigé ajoute sa ligne.
- La documentation de l'API vit dans `server/README.md` : chaque route ajoutée ou modifiée s'y met à jour.
