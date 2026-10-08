# ADR-0050 — Garde-fous du serveur : clé TMDB, tâches de fond, caches, base

- **Statut :** accepté. Le Go est testé et l'image a été lancée en local sous root et sous
  `PUID=1000` ; **la copie d'avant-migration n'a pas été essayée sur une vraie base en service.**
- **Date :** 2026-10-08
- **Portée :** `server/tmdb/`, `server/safego/`, `server/ttlcache/`, `server/database/backup.go`,
  `server/docker-entrypoint.sh`, `server/Dockerfile`, les en-têtes de `server/webui/webui.go`, et
  tous les appelants de TMDB et lanceurs de goroutines du serveur.

## Contexte

Un audit du serveur a relevé cinq défauts qui n'apparaissent dans aucun test fonctionnel, parce
qu'ils ne se voient que lorsque quelque chose tourne mal :

- TMDB v3 s'authentifie par `api_key` dans l'URL, écrite à 27 endroits. Une erreur réseau de
  `net/http` cite l'URL entière, et ces erreurs partaient telles quelles dans le journal.
- Les caches de réponses TMDB n'évinçaient rien. Celui des fiches du catalogue des demandes a pour
  clé un identifiant TMDB quelconque : il grossissait jusqu'au redémarrage.
- Une panique dans une goroutine de fond (scan, enrichissement, ménage) arrêtait le processus, et
  avec lui toutes les lectures en cours.
- Une migration de schéma ne se défait pas, et rien ne copiait la base avant.
- Le conteneur tournait sous root, sans alternative.

## Décision

1. **`tmdb.Get` est le seul chemin vers l'API TMDB.** L'appelant donne le chemin
   (`"/tv/1399?language=fr-FR"`) et son client `httpx` ; le package pose la clé et retire l'URL de
   toute erreur avant qu'elle ne remonte. Garde : `TestOnlyThisPackageBuildsTMDBURLs` refuse
   `api.themoviedb.org` et `api_key=` hors du package.
2. **Toute goroutine passe par `safego`.** `safego.Run` pour une tâche qui a une fin,
   `safego.Forever` pour une boucle — relancée cinq secondes après une panique —, ou
   `defer safego.Recover(…)` en première ligne d'une goroutine anonyme. Garde :
   `TestEveryGoroutineIsGuarded`.
3. **Un cache en mémoire a un plafond** : `ttlcache.New(ttl, max)`. À la limite il rend ses entrées
   expirées, puis la plus ancienne.
4. **La base est copiée avant toute migration** (`VACUUM INTO`, à côté d'elle, trois copies
   gardées), sauf si elle est neuve. Une copie qui échoue arrête le démarrage ;
   `DB_SKIP_MIGRATION_BACKUP=true` s'en passe.
5. **`PUID`/`PGID` font tourner le conteneur sans privilèges**, à la demande. Sans eux, rien ne
   change.
6. Le bundle web est servi avec `X-Content-Type-Options: nosniff` et `Referrer-Policy: no-referrer`.

## Alternatives écartées

- **Masquer la clé dans le journal** (un filtre sur `slog`). Une ligne, mais qui laisse 27 URL
  écrites à la main et ne protège pas une erreur renvoyée ailleurs que dans le journal.
- **Laisser le processus s'arrêter sur une panique** et compter sur `restart: unless-stopped`. Le
  serveur se relève, mais chaque spectateur perd sa lecture pour une erreur dans une tâche qu'il
  n'attendait pas.
- **Non-root par défaut.** Les installations en place ont un `./data` créé par root : après une
  simple mise à jour, le serveur n'aurait plus pu ouvrir sa base. Et un compte sans privilèges perd
  l'accès à `/dev/dri` tant qu'on ne lui donne pas le groupe du périphérique.
- **Une CSP sur le bundle web.** Flutter web charge du WebAssembly, des workers et parle à des
  serveurs que l'utilisateur ajoute lui-même : une politique écrite sans l'essayer dans un
  navigateur casse l'app entière. À faire à part, navigateur ouvert.
- **`X-Frame-Options`.** Les tableaux de bord de serveurs personnels (Organizr, Heimdall) affichent
  les apps dans un cadre ; l'interdire est un choix de produit, pas un correctif.

## Conséquences

- Une boucle de fond qui panique à chaque tour écrit sa pile dans le journal toutes les cinq
  secondes : bruyant, mais c'est le signal qu'on veut, et le reste du serveur continue.
- Une panique survenue en tenant un verrou sans `defer` peut laisser ce verrou pris ; la boucle
  relancée s'y bloquerait. Aucun cas connu.
- La copie d'avant-migration demande la place d'une base de plus sur le disque, trois fois au plus.
- Les appels TMDB lancés par une tâche de fond partent toujours sans `context` :
  `tmdb.GetContext` existe, mais les tâches de l'indexeur n'en portent pas encore un à transmettre.
