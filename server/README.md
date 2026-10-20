# 🚀 Onyx — Serveur Média (Back-End Go)

Un serveur multimédia ultra-léger écrit en Go, conçu exclusivement pour du **Direct Play pur à 100 %**, avec une consommation de RAM minimale (inférieure à 20 Mo) et des performances exceptionnelles.

---

## 🛠 Architecture & Choix Techniques

- **Langage :** Go (Golang) pour sa rapidité et sa gestion native du streaming HTTP par morceaux (`http.ServeFile`).
- **Base de données :** SQLite (avec pilote pur Go `modernc.org/sqlite` — pas besoin de compilateur CGO/gcc).
- **Mode WAL activé :** Toutes les écritures de progression et de synchronisation s'effectuent sans bloquer la lecture grâce au mode *Write-Ahead Logging* (`PRAGMA journal_mode=WAL;`).
- **Indexeur Intelligent :** Scanne automatiquement les disques, structure de manière hiérarchique les séries/saisons/épisodes, nettoie la base de données des fichiers supprimés et filtre le "bruit" des noms de fichiers.
- **Direct Play :** Utilise le protocole natif des *HTTP Range Requests* (code HTTP `206 Partial Content`), permettant des sauts temporels instantanés sans solliciter le CPU ou la mémoire du serveur.

---

## 📂 Structure du Code Source

```
server/
├── Dockerfile               # Image Docker multi-stage optimisée (< 20 Mo)
├── go.mod                   # Gestionnaire des dépendances
├── main.go                  # Point d'entrée, configuration & routage API
├── database/
│   └── database.go          # Initialisation SQLite, PRAGMA WAL & migrations
├── models/
│   └── models.go            # Structs Go (User, Media, Progression, etc.)
├── indexer/
│   └── indexer.go           # Indexation intelligente, regex SxxExx, auto-nettoyage
└── handlers/
    ├── auth.go              # Inscription, Connexion, Profil, Middleware d'Auth
    ├── media.go             # Dashboard, Progressions & Navigation Bibliothèque
    └── stream.go            # Streaming de fichiers par morceaux (Direct Play)
```

---

## ⚙️ Comment lancer le serveur (Docker Compose)

Le projet intègre un fichier `docker-compose.yml` à la racine pour un déploiement instantané.

### 1. Préparation des Dossiers
Créez vos dossiers de médias locaux s'ils n'existent pas encore :
```bash
mkdir -p data media/Films media/Series
```

### 2. Démarrage
Lancez l'environnement avec Docker Compose :
```bash
docker compose up -d --build
```
Le serveur démarrera sur le port **8080** (http://localhost:8080) et créera la base de données SQLite dans `./data/player.db`.

Les sous-titres extraits et les aperçus de la barre de lecture sont rangés à côté de la base. Avant toute migration du schéma, la base est copiée à côté d'elle (`player.db.pre-<migration>-<date>.bak`, les trois dernières sont gardées) ; `DB_SKIP_MIGRATION_BACKUP=true` s'en passe quand le disque n'a pas la place. Le conteneur tourne sous root par défaut ; `PUID` (et `PGID`) le font tourner sous un compte sans privilèges, à qui `./data` est rendu au démarrage — les dossiers de médias doivent alors lui être lisibles. Le journal s'écrit en texte sur la sortie d'erreur ; `LOG_FORMAT=json` donne une ligne JSON par entrée, et `LOG_LEVEL` (`debug`, `info`, `warn`, `error`) règle ce qui est écrit.

---

## 📡 Documentation de l'API REST

**`GET /api/ping`** (public) dit que le serveur répond, et ce qu'il est : `{"status":"ok","version":"main-abc1234","playback_ticket_version":1,"capabilities":["playback_tickets","progress_long_poll","media_language","watched_by_credits"]}`. Une app lit `capabilities` pour savoir ce que ce serveur sait faire ; la liste est tenue dans `handlers/ping.go`. Les réponses que l'app lit par un modèle ont leur forme de référence dans `contract/` (ADR-0051).

Toutes les routes API (sauf l'inscription/connexion et le stream) requièrent l'en-tête HTTP d'authentification suivant :
`Authorization: Bearer <votre_token_de_session>`

### 🔑 1. Authentification

#### ➡️ Inscription
* **Route :** `POST /api/auth/register`
* **L'inscription libre est fermée.** Elle n'aboutit que dans deux cas : la base n'a encore aucun
  compte (ce premier compte devient le **propriétaire** et reçoit tous les droits), ou un token
  d'invitation valide est fourni.
* Le nom d'utilisateur ne distingue pas la casse : `Mathis` est refusé (`409`) si `mathis` existe
  déjà. La graphie choisie est conservée pour l'affichage.
* **Corps (JSON) :**
  ```json
  {
    "username": "mon_pseudo",
    "password": "mon_super_mot_de_passe",
    "invite_token": "a7f3…"
  }
  ```

#### ➡️ État du serveur
* **Route :** `GET /api/auth/state` — publique, n'expose qu'un booléen.
* **Réponse (JSON) :** `{ "setup_required": true }` tant qu'aucun compte n'existe.

#### ➡️ Connexion
* **Route :** `POST /api/auth/login`
* **Corps (JSON) :** `username` + `password`. Le nom d'utilisateur ne distingue pas la casse
  (`MATHIS` ouvre le compte `Mathis`) ; si une ancienne base contient deux comptes qui ne diffèrent
  que par la casse, la graphie exacte l'emporte.
* **Réponse (JSON) :**
  ```json
  {
    "token": "45d17ff25988ba97b819...",
    "user": {
      "id": 1,
      "username": "mon_pseudo",
      "is_owner": true,
      "permissions": { "manage_settings": true, "manage_library": true, "manage_users": true,
                       "delete_media": true, "invite_users": true, "request_media": true },
      "invite_grants": { "request_media": true },
      "otp_enabled": false
    }
  }
  ```
* **Code de vérification (ADR-0041) :** quand le compte a configuré la validation en deux étapes,
  ou que la politique du serveur la lui impose, la connexion répond `401` avec un objet `otp` au
  lieu d'une session :
  ```json
  { "error": "Code de vérification requis…",
    "otp": { "challenge": "9f2c…", "setup": false } }
  ```
  Avec `"setup": true`, l'objet porte aussi `secret` et `uri` (`otpauth://…`) à scanner. La session
  s'obtient ensuite par `POST /api/auth/otp/login`, corps `{ "challenge": "…", "code": "123456" }`
  (le code de l'application ou un code de secours) : même réponse que la connexion, plus
  `recovery_codes` quand le code vient d'être configuré. `401` : code faux ; `410` : étape expirée
  (5 minutes, 5 essais), il faut recommencer la connexion.

#### ➡️ Validation en deux étapes du compte (ADR-0041)
* `GET /api/auth/otp` — `{ "policy", "enabled", "required", "recovery_codes_left" }`.
* `POST /api/auth/otp/setup` — tire un secret : `{ "secret", "uri" }`. `403` si la politique est
  `disabled`, `409` si un code est déjà configuré.
* `POST /api/auth/otp/enable` — `{ "code" }` ; active et rend `{ "recovery_codes": [...] }`.
  `400` : code faux.
* `POST /api/auth/otp/disable` — `{ "password" }`. `403` si la politique l'impose à ce compte.
* `POST /api/auth/otp/recovery-codes` — `{ "password" }` ; remplace les codes de secours.
* La politique est le réglage `otp_policy` de `GET/PUT /api/settings` (`manage_settings`) :
  `disabled`, `optional` (défaut), `admins`, `everyone`. Variable d'environnement de repli :
  `OTP_POLICY`.

#### ➡️ Liaison avec OnyxHub (ADR-0072)
* Réglée par `mediahub_url` et `mediahub_api_key` dans `PUT /api/settings` (`manage_settings`) ;
  OnyxHub peut les écrire lui-même avec le jeton de son admin (« Connecter Onyx »).
* Chaque appel relayé vers OnyxHub porte `Authorization: Bearer <mediahub_api_key>`,
  `X-Player-Username` et `X-Player-Id` (ADR-0075). Les formats échangés sont dans
  `contract/onyxhub/`, relus par les tests d'Onyx et d'OnyxHub.
* `POST /api/settings/mediahub/test` (`manage_settings`) — body facultatif
  `{ "mediahub_url", "mediahub_api_key" }` (vides : les valeurs enregistrées). Le serveur appelle
  `GET {url}/api/integration/ping` avec la clé et rend toujours `200`
  `{ "ok", "message", "service"?: "onyxhub"|"mediahub", "version"? }`. Un MediaHub (sans ping) est
  reconnu à sa route de disponibilité. Capacité `mediahub_link_test` sur `/api/ping`.
* Le catalogue de demandes lit les disponibilités d'une page en un appel
  (`POST {url}/api/media/availability`, `{ "items": [{ "tmdbId", "mediaType" }] }`) ; sur `404`/`405`
  (MediaHub, OnyxHub ancien), il retombe sur `GET {url}/api/media/availability/:id` par carte
  et ne retente le lot qu'au bout de 10 minutes.
* `GET /api/requests/mine` (`request_media`, ADR-0073) — relaie `GET {url}/api/request` au nom du
  compte : `{ "requests": [{ "tmdbId", "mediaType", "title", "posterPath", "seasons", "status",
  "requestedAt", "progress" }] }`, tel qu'OnyxHub le rend. Capacité `my_requests`.
* `GET /api/library/tmdb-index` (`RequireAuth`, ADR-0073) — `{ "movies": { "<tmdb>": id },
  "shows": { "<tmdb>": id } }`, la plus ancienne fiche de chaque titre. L'app web ouvre une fiche
  depuis `?movie=ID` ou `?show=ID`. Capacité `library_tmdb_index`.
* `POST /api/integrations/onyxhub/imported` (sans compte, `Authorization: Bearer <mediahub_api_key>`,
  ADR-0074) — `{ "tmdbId", "mediaType", "paths": [...] }` (100 au plus) → `202 { "status": "queued" }`.
  Oublie le statut en cache du titre, parcourt le dossier de chaque chemin qui tombe dans une
  bibliothèque, et avance le poll du moniteur (au plus une fois toutes les 30 s). `401` sans la
  bonne clé. Capacité `onyxhub_import_signal`.

#### ➡️ Profil connecté
* **Route :** `GET /api/auth/me` — même charge utile que `user` ci-dessus.

#### ➡️ Changer son mot de passe
* **Route :** `POST /api/auth/password`
* **Corps (JSON) :** `{ "current_password": "…", "new_password": "…" }`

#### ➡️ Supprimer son compte
* **Route :** `POST /api/auth/account/delete`
* **Corps (JSON) :** `{ "password": "…" }`
* Suppression dure, en cascade (progression, sessions, dispositions du lecteur). `401` si le mot
  de passe est faux, `403` pour le propriétaire, qui doit d'abord transférer la propriété.

---

### 📺 1 ter. Appairage d'un téléviseur (QR code)

Un téléviseur n'a pas de clavier : il ne saisit jamais de mot de passe. Il ouvre un appairage,
affiche le code court en QR, et attend qu'un téléphone **déjà connecté** l'approuve. La session est
créée au moment de l'approbation, sous l'identité de celui qui approuve — la TV hérite donc
exactement de son compte et de ses droits.

La forme est celle du device flow OAuth (RFC 8628) : `start` → `poll` → `approve`.

Décisions détaillées : `docs/adr/0003-android-tv-et-appairage-par-qr-code.md`.

#### ➡️ Ouvrir un appairage (depuis la TV, non authentifié)
* **Route :** `POST /api/auth/device/start`
* **Corps (JSON) :** `{ "device_name": "Salon" }` — facultatif, purement cosmétique.
* **Réponse :** `{ "device_code": "…", "user_code": "ABCD2FGH", "expires_in": 300, "interval": 2 }`

`device_code` est le secret de 256 bits que seule la TV détient ; `user_code` est la moitié courte,
affichée à l'écran et encodée dans le QR. Le QR pointe sur `<serveur>/?tv=<user_code>`, composé
côté client — derrière un proxy le serveur ignore sa propre adresse publique.

#### ➡️ Interroger l'appairage (depuis la TV, non authentifié)
* **Route :** `POST /api/auth/device/poll`
* **Corps (JSON) :** `{ "device_code": "…" }`
* **Réponse :** `{ "status": "pending" | "expired" | "approved", "token": "…", "user": {…} }`

`token` et `user` ne sont servis que sur `approved`, et **une seule fois** : la récupération
consomme l'appairage. Un code inconnu et un code déjà consommé répondent tous deux `expired`.

#### ➡️ Décrire un code en attente (depuis le téléphone)
* **Route :** `GET /api/auth/device/pending?code=ABCD2FGH`
* **Réponse :** `{ "user_code": "…", "device_name": "Salon", "expires_in": 240 }`

#### ➡️ Approuver / refuser (depuis le téléphone)
* **Routes :** `POST /api/auth/device/approve` · `POST /api/auth/device/deny`
* **Corps (JSON) :** `{ "user_code": "ABCD2FGH" }` — tiret, minuscules et espaces sont tolérés.

Un code vit **5 minutes**, fait 8 caractères tirés d'un alphabet de 32 symboles sans `I`, `O`, `0`
ni `1`, et ne peut être approuvé qu'une fois : deux téléphones qui lisent le même écran ne
produisent pas deux sessions.

#### Côté application

Le même APK s'installe sur téléphone et sur Android TV (`LEANBACK_LAUNCHER`, écran tactile déclaré
facultatif). Le mode télécommande est détecté au démarrage et forçable dans **Paramètres →
Téléviseur → Mode télécommande**. Sur la TV, l'écran de connexion affiche le QR ; le formulaire mot
de passe reste accessible à un bouton, pour le premier compte d'un serveur vierge. Depuis un
téléphone, **menu compte → Connecter une TV** permet aussi de taper le code à la main.

L'**Apple TV** a sa propre cible (`app/tvos/`, construite avec flutter-tvos) et la même interface
à la télécommande : Siri Remote, manette ou clavier, avec les mêmes touches qu'Android TV. Le
lecteur y est AVPlayer, alimenté en HLS par le serveur, qui recopie les pistes au lieu de les
ré-encoder. Build, installation et limites : [ADR-0028](docs/adr/0028-cible-apple-tv.md) et
`scripts/build-tvos-ipa.sh`.

---

### 👥 1 bis. Droits, utilisateurs & invitations

Sept permissions indépendantes par compte : `manage_settings`, `manage_library`, `manage_users`,
`delete_media`, `invite_users`, `request_media` (seule accordée par défaut) et `share_media`
(créer des liens de partage publics, section 5 bis). « Administrateur »
n'est qu'un raccourci d'interface qui les coche toutes.

Le **propriétaire** (premier compte) est asymétrique : il peut retirer ses droits à n'importe quel
administrateur, personne ne peut lui retirer les siens. Il peut transférer son statut. Le serveur
refuse par ailleurs toute opération qui ne laisserait plus aucun compte avec `manage_users`.

Décisions détaillées : `docs/adr/0001-user-permissions-and-invitations.md`.

* `GET /api/users` — liste des comptes et de leurs droits (`manage_users`).
* `PUT /api/users/:id/permissions` — corps `{ "permissions": {…}, "invite_grants": {…} }`.
* `POST /api/users/:id/password` — réinitialisation ; ferme toutes les sessions du compte visé.
* `DELETE /api/users/:id/otp` — retire la validation en deux étapes d'un compte qui a perdu son
  téléphone. Celle du propriétaire, seul le propriétaire la retire.
* `DELETE /api/users/:id` — suppression dure, en cascade. Ni le propriétaire, ni soi-même.
* `POST /api/users/:id/transfer-ownership` — réservé au propriétaire.

Invitations (`invite_users` ou `manage_users`) : liens **à usage unique**, valables **7 jours**,
révocables. Les droits accordés sont figés à la création et proviennent du **gabarit**
(`invite_grants`) fixé par un administrateur — celui qui invite ne les choisit pas, ce qui empêche
le droit d'inviter de devenir un chemin vers l'administration.

* `GET /api/invitations` — ses propres liens ; tous les liens avec `manage_users`.
* `POST /api/invitations` — génère un lien.
* `DELETE /api/invitations/:token` — révoque un lien en attente.

Retirer `invite_users` à un compte révoque en cascade ses liens en attente ; modifier son gabarit
n'affecte que les liens futurs.

#### 📣 Message aux utilisateurs (ADR-0069)

Un administrateur écrit un message ; chaque compte le voit en grand à sa prochaine ouverture de
l'app, une seule fois. Le serveur annonce la capacité `announcements` sur `/api/ping`.

* `GET /api/me/announcement` — `{ "announcement": { "id", "title", "message", "created_at" } }`
  si le compte ne l'a pas encore fermé, sinon `{ "announcement": null }`.
* `POST /api/me/announcement/seen` — corps `{ "id": 3 }` ; la marque ne recule jamais.
* `GET /api/announcement` (`manage_settings`) — le message en cours, lu ou non.
* `PUT /api/announcement` (`manage_settings`) — corps `{ "title": "…", "message": "…" }`
  (titre facultatif, 120 caractères ; message obligatoire, 4 000 caractères). Remplace le
  précédent et le remontre à tous, sauf à son auteur.
* `DELETE /api/announcement` (`manage_settings`) — retire le message.

#### 🔖 Listes : « À regarder plus tard » et listes partagées (ADR-0070)

Chaque compte a une liste `watch_later`, créée à la première lecture, et peut en composer
d'autres (`custom`). Une liste partagée (`is_shared`) se lit par tous les comptes du serveur ;
seul son propriétaire la modifie, et une liste privée répond 404 aux autres. Un élément est un
film ou une série, sur le serveur (`media_id`) ou seulement dans le catalogue TMDB : ce dernier
se rattache tout seul à la fiche qui arrive avec le même `tmdb_id`. Le serveur annonce la
capacité `watch_lists` sur `/api/ping`.

* `GET /api/lists` — `{ "mine": [liste…], "shared": [liste…] }`, « à regarder plus tard » en
  tête. Une liste : `{ "id", "kind", "name", "description", "is_shared", "is_mine",
  "owner": { "id", "username" }, "item_count", "posters": [4 au plus], "updated_at" }`.
  Avec `?media_id=12` ou `?tmdb_id=603&media_type=movie`, chacune de `mine` porte
  `contains_item_id` (0 si le titre n'y est pas).
* `POST /api/lists` — corps `{ "name": "Mes recos", "description": "", "is_shared": true }`
  (nom de 80 caractères, description de 500, 200 listes par compte) → la liste, `201`.
* `GET /api/lists/:id` — la liste et `items`, du plus récent ajout au plus ancien :
  `{ "id", "media_type": "movie"|"show", "tmdb_id", "title", "poster_url", "release_date",
  "added_at", "media_id", "media" }`. `media_id` vaut 0 quand le serveur n'a pas le titre ;
  sinon `media` est sa fiche, avec la progression du compte qui lit.
* `PUT /api/lists/:id` — même corps que la création. « À regarder plus tard » ne garde que
  `is_shared`.
* `DELETE /api/lists/:id` — supprime la liste ; `409` pour « à regarder plus tard ».
* `POST /api/lists/:id/items` — `{ "media_id": 12 }` pour une fiche du serveur, ou
  `{ "tmdb_id": 603, "media_type": "movie"|"show", "title": "…", "poster_path": "/abc.jpg",
  "release_date": "1999-03-31" }` pour un titre du catalogue. Un titre déjà présent revient tel
  quel. 1 000 titres par liste.
* `DELETE /api/lists/:id/items/:item` — retire un titre.

---

### 🏠 2. Accueil & Progression

#### ➡️ Page d'Accueil (Dashboard)
* **Route :** `GET /api/home`
* **Rangées par bibliothèque :** la réponse porte aussi `libraries`, une entrée par bibliothèque qui contient quelque chose : `{"id", "name", "kind", "items": [...]}`, `items` étant ses derniers ajouts. `recent_movies` et `recent_shows` restent pour les apps plus anciennes (ADR-0058).
* **Réponse (JSON) :**
  ```json
  {
    "continue_watching": [
      {
        "id": 12,
        "type": "movie",
        "title": "Inception",
        "file_path": "/media/Films/Inception.mkv",
        "duration": 8880,
        "current_position_seconds": 1240,
        "is_finished": false,
        "created_at": "2026-06-15T14:00:00Z"
      }
    ],
    "recent_movies": [...],
    "recent_shows": [...]
  }
  ```

#### ➡️ Suivre la progression en direct
* **Route :** `GET /api/progress/revision?since=<jeton>`
* **Note de fonctionnement :** rend un jeton opaque qui change dès que ce que le compte a regardé
  change (position envoyée par un autre appareil, média coché vu, entrée retirée de « Reprendre la
  lecture »). Le jeton se compare au précédent, rien d'autre.
  * Sans `since` : répond tout de suite avec le jeton courant.
  * Avec `since` (long-poll) : attend que le jeton s'en écarte, au plus 20 secondes, puis répond
    avec le jeton courant — inchangé si rien n'a bougé. L'accueil et les fiches gardent une telle
    requête ouverte tant qu'ils sont à l'écran et relisent leurs données quand elle rend un jeton
    neuf.
* **Réponse (JSON) :**
  ```json
  { "revision": "1284.37.2.2026-10-07 18:02:11" }
  ```

#### ➡️ Enregistrer la progression (Heartbeat du lecteur)
* **Route :** `POST /api/progress`
* **Note de fonctionnement :** Cet endpoint met à jour la position de lecture. Si le pourcentage de lecture atteint ou dépasse **90%**, le média est automatiquement marqué comme `is_finished = true` (vu) et retiré de "Reprendre la lecture". De plus, le serveur met à jour dynamiquement la durée totale du média reçue de l'application cliente pour éviter de l'analyser sur le serveur.
* **Corps (JSON) :**
  ```json
  {
    "media_id": 12,
    "current_position_seconds": 1240,
    "duration": 8880,
    "is_finished": false
  }
  ```
* **Rejeu d'une lecture hors ligne :** un client qui a regardé un média téléchargé sans réseau
  ajoute `"client_updated_at"` (RFC3339, date de la lecture, pas de l'envoi). Le serveur refuse
  alors d'écraser une progression plus récente venue d'un autre appareil, et répond avec l'état
  réellement stocké. Le champ est facultatif : un battement de coeur normal l'omet et vaut
  « maintenant ». Voir `docs/adr/0010-telechargements-hors-ligne.md`.
  ```json
  {
    "media_id": 12,
    "current_position_seconds": 1240,
    "duration": 8880,
    "is_finished": true,
    "client_updated_at": "2026-09-01T20:14:03Z"
  }
  ```

#### 🎚 Réglages de lecture du compte
Les préférences qui suivent la personne d'un appareil à l'autre (saut d'intro automatique, langue
audio par défaut). Les réglages liés au matériel restent sur l'appareil. Voir
`docs/adr/0043-reglages-de-lecture-lies-au-compte.md`.
* **Route :** `GET /api/me/playback-preferences`
* **Réponse (JSON) :** `updated_at` est vide tant que le compte n'a rien enregistré.
  ```json
  {
    "auto_skip_intro": true,
    "default_audio_lang": "fr",
    "still_watching_enabled": true,
    "still_watching_episodes": 3,
    "still_watching_from": 1320,
    "still_watching_until": 360,
    "updated_at": "2026-10-05 18:22:10"
  }
  ```
* **Route :** `PUT /api/me/playback-preferences`
* **Corps (JSON) :** partiel — un champ absent garde sa valeur. `default_audio_lang` est un code de
  deux ou trois lettres, ou `""` pour la piste par défaut du fichier (`400` sinon).
  `still_watching_enabled` vaut `false` tant qu'on ne l'a pas allumé.
  `still_watching_episodes` va de 1 à 10. `still_watching_from` et `still_watching_until` sont des
  minutes depuis minuit (0–1439, différentes, la plage peut passer minuit), ou `-1` toutes les deux
  pour toute la journée (`400` sinon). Voir `docs/adr/0045-vous-regardez-encore.md`.
  ```json
  { "auto_skip_intro": true }
  ```
* **Réponse (JSON) :** l'état stocké, au même format que le `GET`.

#### 🗣 Pistes retenues par série
La langue audio et le sous-titre choisis dans un épisode valent pour toute sa série, sur tous les
appareils du compte. Voir `docs/adr/0044-pistes-retenues-par-serie.md`.
* **Route :** `GET /api/episodes/:id/track-preferences` (`404` si le média n'est pas un épisode)
* **Réponse (JSON) :** `updated_at` est vide tant que rien n'a été choisi pour la série ;
  `subtitle.mode` vaut `""` (pas de choix), `"off"` ou `"on"` ; `await_audio_lang` est vide tant
  que le compte n'attend aucune langue pour cette série.
  ```json
  {
    "show_id": 42,
    "audio_lang": "en",
    "subtitle": { "mode": "on", "lang": "fr", "key": "fr", "forced": false, "image": false },
    "await_audio_lang": "",
    "updated_at": "2026-10-05 21:04:11"
  }
  ```
* **Route :** `PUT /api/episodes/:id/track-preferences`
* **Corps (JSON) :** partiel — `audio_lang`, `subtitle` et `await_audio_lang` sont indépendants
  (`400` si invalide). Choisir un `audio_lang` différent de la langue attendue lève l'attente.
  ```json
  { "subtitle": { "mode": "off" } }
  ```
* **Réponse (JSON) :** l'état stocké, au même format que le `GET`.

#### ⏳ Attendre sa langue
Une série suivie en VF dont l'épisode suivant n'existe encore qu'en VO. Voir
`docs/adr/0057-attendre-sa-langue.md`.
* `GET /api/episodes/:id/next` joint `episode_audio_langs` à `episode` : les langues audio de
  l'épisode suivant (`["ja", "fr"]`), celle de sa piste par défaut en tête. La clé est absente
  tant que le fichier n'a pas été sondé ou qu'aucune piste ne déclare sa langue.
* `PUT /api/episodes/:id/track-preferences` avec `{ "await_audio_lang": "fr" }` : le compte
  attend le français pour cette série ; `""` cesse d'attendre.
* Tant que l'épisode à reprendre n'a pas la langue attendue, la série n'apparaît plus dans
  `continue_watching` de `GET /api/home`. Elle y revient avec `has_new_episode: true` quand la
  piste arrive, même sur un fichier présent depuis longtemps — et même si la série n'a jamais
  été commencée.

---

### 📂 3. Navigation Bibliothèque

#### 🌐 Langue des fiches
Les titres et synopsis sont servis dans la langue que le client annonce par l'en-tête
`Accept-Language` (`fr` ou `en`, les langues de l'interface — ADR-0049). Sans en-tête, ou avec une
autre langue, la réponse reste dans la « langue des métadonnées » du serveur ; si l'en-tête liste
plusieurs langues, la première des deux l'emporte. Concerne l'accueil,
les listes de films, séries et épisodes, la reprise, l'épisode suivant, les fiches détaillées, les
personnes, les sagas et le catalogue des demandes. Un texte que TMDB n'a pas dans la langue
demandée reste dans celle du serveur.

#### 📚 Bibliothèques
Une bibliothèque est un dossier du serveur, le nom que son administrateur lui donne et la façon de
le lire (`kind` : `movies`, un fichier est un film à identifier ; `shows`, des épisodes rangés par
série ; `other`, des vidéos présentées sous le nom de leur fichier, jamais identifiées).
Le serveur n'en impose aucune et n'en limite pas le nombre (ADR-0058). Il annonce la capacité
`libraries` sur `GET /api/ping`.

* **`GET /api/libraries`** (compte connecté) : `[{"id": 1, "name": "Animés", "kind": "shows", "path": "/media/Animes"}]`, par ordre de création. `path` n'est joint que pour `manage_settings`.
* **`POST /api/libraries`** (`manage_settings`) : corps `{"name", "kind", "path"}`. `201` et la bibliothèque créée ; une analyse démarre. `400` si le nom est vide ou dépasse 40 caractères, si le type est inconnu, si le chemin n'est pas absolu ou n'est pas un dossier que le serveur voit ; `409` si le dossier est déjà celui d'une bibliothèque.
* **`PUT /api/libraries/:id`** (`manage_settings`) : corps `{"name", "path"}`. Le type ne se change pas. Changer le dossier retire du catalogue ce qui était indexé sous l'ancien et analyse le nouveau.
* **`DELETE /api/libraries/:id`** (`manage_settings`) : `204`. Retire la bibliothèque et ses titres du catalogue, avec leur progression. Les fichiers ne sont pas touchés.

#### ➡️ Liste des Films
* **Route :** `GET /api/movies`
* **Paramètre :** `library=ID` (optionnel) limite la liste à une bibliothèque ; sans lui, tout le serveur. `404` pour une bibliothèque inconnue.
* **Réponse (JSON) :** Liste des films avec la progression de l'utilisateur connecté sous chaque film (si commencée).

#### ➡️ Liste des Séries
* **Route :** `GET /api/shows`
* **Paramètre :** `library=ID` (optionnel) : les séries dont au moins un épisode se trouve dans cette bibliothèque.
* **Réponse (JSON) :** Liste des séries TV indexées.

#### ➡️ Liste des Saisons d'une Série
* **Route :** `GET /api/shows/:id/seasons`
* **Réponse (JSON) :** Saisons présentes et saisons connues de TMDB mais absentes (`id` 0, `is_available` false). Chaque saison porte `request_status`, `can_request` et `episode_count` (total TMDB). Une saison présente mais incomplète annonce elle aussi l'état de sa demande MediaHub, et `can_request` true quand personne ne l'a demandée.

#### ➡️ Liste des Épisodes d'une Saison
* **Route :** `GET /api/seasons/:id/episodes`
* **Paramètre :** `missing=1` (optionnel) ajoute les épisodes annoncés par TMDB que le serveur n'a pas — à venir ou absents — avec `id` 0, `is_available` false et leur date de sortie dans `release_date`. Chaque épisode porte alors `is_available`.
* **Réponse (JSON) :** Liste complète des épisodes de la saison avec l'état de progression/lecture associé à chaque épisode pour l'utilisateur connecté.

---

### 🔄 4. Indexation & Scan

#### ➡️ Surveillance automatique
* **Comportement :** Le serveur surveille le dossier de chaque bibliothèque. Un fichier déposé (nouveau film, nouvel épisode) est indexé en quelques secondes, et un fichier supprimé est retiré, sans scan manuel. Seul le dossier modifié est scanné.
* **Configuration :** `LIBRARY_WATCH` (`true` par défaut) active les notifications du système de fichiers ; `LIBRARY_POLL_INTERVAL` (`5m` par défaut, `0` pour désactiver) règle la vérification périodique des dossiers, qui rattrape ce que les notifications ne voient pas sur un partage réseau. Détails : `docs/adr/0018-surveillance-de-la-mediatheque.md`.

#### ➡️ Lancer un scan de la bibliothèque
* **Route :** `POST /api/indexer/scan`
* **Comportement :** Lance un scan de dossiers asynchrone (en arrière-plan) et renvoie immédiatement un accusé de réception.
* **Réponse (JSON) :** `{"status": "success", "message": "Scan triggered in background"}`

#### ➡️ Récupérer l'état du scan
* **Route :** `GET /api/indexer/status`
* **Réponse (JSON) :** `{"is_scanning": true/false, …, "library_monitor": {"running": true, "notifications": true, "folders": 1234, "pending_folders": 0, "pending_files": 0, …}}`

#### 🖼 Choisir l'affiche d'un film ou d'une série
Exige `manage_library`. Détails : `docs/adr/0068-affiche-choisie-parmi-tmdb-et-fanart.md`.
* **Proposer :** `GET /api/media/:id/images/posters` → `{"current": "…", "locked": false, "fanart_enabled": true, "images": [{"url", "thumb_url", "source": "tmdb"|"fanart", "language", "width", "height", "rating", "votes"}]}`. Les affiches dans la langue de l'interface d'abord, puis sans texte, puis en anglais. Fanart.tv n'est interrogé que si une clé est réglée (`fanart_api_key` dans `PUT /api/settings`, ou `FANART_API_KEY`). Liste vide pour une fiche que TMDB n'a pas identifiée.
* **Choisir :** `PUT /api/media/:id/poster` avec `{"url": "…"}` (une adresse de `image.tmdb.org` ou `assets.fanart.tv`, sinon `400`) → la fiche à jour. L'affiche est protégée de l'enrichissement automatique ; les saisons et épisodes qui portaient l'ancienne affiche de la série suivent.
* **Revenir à l'affiche par défaut :** `DELETE /api/media/:id/poster` → la fiche à jour.

---

### 🎬 5. Lecture Vidéo (Direct Play)

* **Route :** `GET /stream?media_id=12&ticket=…`
* **Note importante :** Pas d'en-tête de session, parce que les lecteurs vidéo (ExoPlayer, mpv, AVPlayer) injectent mal les en-têtes personnalisés. L'accès passe par un ticket de lecture temporaire dans l'URL (`POST /api/playback/tickets`), voir `docs/playback-tickets.md`.
* **Comportement :** Émet des Range Requests. Supporte le streaming par morceaux, le multi-pistes, le chargement des sous-titres intégrés et les seeks fluides.

#### ➡️ Transcodage (HLS)
* **Configuration :**
  * `ONYX_DEV_LINE_KBPS` : **développement seulement.** Bride tous les flux vidéo (Direct Play et segments HLS) à ce débit, pour reproduire une ligne lente ; `0` démarre libre. Quand la variable est définie, `PUT /api/dev/line?kbps=N` (administrateur) change le débit pendant une lecture. Voir ADR-0056.
  * `VIDEO_ENCODER` : l'encodeur H.264 des sessions. Non défini : `libx264`, sur le processeur. `auto` prend le premier encodeur matériel qui encode réellement une image au démarrage (`h264_videotoolbox`, `h264_nvenc`, `h264_qsv`, `h264_vaapi`) ; un nom précis le force. Tout échec retombe sur `libx264` et le journal le dit. Sous Docker, le circuit d'un processeur Intel ou AMD demande en plus `devices: - /dev/dri:/dev/dri`. Voir ADR-0023.
  * `VAAPI_DEVICE` : le nœud de rendu donné à `h264_vaapi` (`/dev/dri/renderD128` par défaut).
  * `MAX_TRANSCODES` : nombre maximal de sessions simultanées (par défaut la moitié des cœurs, au moins 4 ; `0` retire la limite). Au-delà, `/start` répond 503 avec `Retry-After`.
  * `HLS_DIR` : dossier de travail des sessions (par défaut `onyx-hls` dans le dossier temporaire du système). Les sessions laissées par un arrêt brutal y sont effacées au démarrage.
  * `HLS_MIN_FREE_MB` : espace libre minimal sur ce dossier pour ouvrir une session (`2048` par défaut, `0` pour désactiver).
  * `HLS_RETAIN_MINUTES` : ce qu'une session garde derrière la lecture quand le client sait rouvrir une session pour reculer plus loin (`30` par défaut). Les clients plus anciens gardent toute leur session.
* **Comportement :** une seule session par ticket de lecture. Celle que remplace une nouvelle session (saut, changement de qualité) est arrêtée trente secondes plus tard si le client ne l'a pas fait lui-même.

---

### 🔗 5 bis. Liens de partage publics

Un film, un épisode, une saison ou une série entière partagé par un lien qui s'ouvre sans compte,
dans un navigateur : `https://serveur/share#<code>`. Le code est dans le fragment, que le navigateur n'envoie jamais :
il ne finit dans aucun journal. Décisions détaillées : `docs/adr/0037-liens-de-partage-publics.md`.

Côté créateur (`share_media`) :

* `POST /api/shares` — corps `{"media_id": 42, "password": "", "single_use": true, "expires_in_hours": 168}`.
  `expires_in_hours` vaut `0` (sans échéance), `24`, `168` ou `720`. Répond `201` avec le lien et son
  `code`, rendu **cette fois seulement** : le serveur n'en garde que l'empreinte SHA-256.
  `media_id` est un film, un épisode, une saison ou une série (`media_type` dans la réponse) ;
  `404` s'il n'y a rien à lire, `400` pour `single_use` sur une saison ou une série.
* `GET /api/shares` — ses liens, avec leur `status` : `active`, `expired` ou `watched`, et leurs
  `viewers` (absent sans spectateur) : `[{"name", "media_id", "season_number", "episode_number",
  "position_seconds", "duration", "finished", "watched_at"}]`, le dernier média que chaque prénom a
  regardé par ce lien, du plus récent au moins récent (ADR-0066).
* `DELETE /api/shares/:id` — supprime le lien et coupe aussitôt les lectures qu'il a ouvertes.

Retirer `share_media` à un compte supprime ses liens.

Côté visiteur, sans compte — le code voyage dans le corps JSON :

* `GET /share` — l'app web, qui ouvre le lien en invité dans le lecteur Onyx.
* `POST /api/shared/info` `{"code", "viewer"}` — faut-il un mot de passe ; le média n'est décrit
  qu'une fois le mot de passe donné. `404` inconnu, `410` expiré ou vu, `409` réservé ailleurs.
  Pour une saison ou une série, `episodes` liste ce qui peut être lu :
  `[{"id", "season_id", "season_number", "episode_number", "title", "duration", "overview",
  "still_url", "release_date", "intro_start", "intro_end", "outro_start", "outro_end"}]`, et
  `details` porte la fiche de la série (comme `GET /api/media/:id/details`, sans rien du disque ni
  des titres similaires).
* `POST /api/shared/contents` `{"code", "password", "viewer"}` — la même description, une fois le
  mot de passe donné, sans rien délivrer : la liste des épisodes d'un lien protégé. Limité comme
  l'ouverture.
* `POST /api/shared/open` `{"code", "password", "viewer", "media_id"}` — délivre un ticket de
  lecture au nom du lien, et le jeton `viewer` du navigateur. Un lien à usage unique est réservé
  par ce navigateur. `media_id` choisit l'épisode d'une saison ou d'une série (`404` s'il n'en fait
  pas partie) ; il est inutile pour un film ou un épisode. Limité comme la connexion, par adresse
  et par lien.
* `POST /api/shared/renew` `{"code", "viewer", "ticket"}` — prolonge le ticket (toutes les 5 min).
* `POST /api/shared/progress` `{"code", "viewer", "ticket", "media_id", "position_seconds"}` — au
  seuil « vu » (90 %), un lien à usage unique est détruit (`{"consumed": true}`). Le navigateur qui
  l'a vu peut encore renouveler son ticket pendant une heure, le temps du générique.
* `POST /api/shared/tracks` `{"code", "viewer", "ticket", "media_id"}` — pistes audio et
  sous-titres, comme `GET /api/media/:id/tracks` ; exige un ticket vivant du lien. Comme pour
  `progress`, `media_id` nomme l'épisode lu dans une saison ou une série.
* `POST /api/shared/close` `{"code", "ticket"}` — révoque le ticket à la fermeture du lecteur.

Le ticket ouvre ensuite les routes habituelles (`/stream`, `/api/v1/stream/…`, sous-titres,
aperçus). Un lien tient au plus quatre lectures simultanées.

---

### 📥 6. Téléchargement des applications clientes

* **Routes :** `GET /api/downloads` · `GET /api/downloads/:fichier`
* **Comportement :** Publie les applications installables (APK Android, DMG macOS, EXE et ZIP Windows, IPA iOS et Apple TV) **de la version du serveur** : celles de la GitHub Release `v<version>` (`server/releasedl`, ADR-0062). Un serveur en 1.2.0 propose les installeurs de la 1.2.0, pas ceux d'une version plus récente ni plus ancienne. Une image de développement (`dev`, `main-<sha>`), qui n'a pas de Release, propose celle de la plus récente. L'image Docker n'embarque aucun installeur. Un installeur est téléchargé depuis GitHub à la première demande, puis resservi depuis `release-cache/` (à côté de la base) ; les installeurs de la version précédente sont supprimés à la mise à jour. Le fichier est servi en `attachment` avec support des Range Requests (une reprise après coupure ne repart pas de zéro). L'APK et les IPA sont servis avec l'adresse de téléchargement glissée dedans (`server/installorigin`, ADR-0042) : l'app installée s'ouvre avec l'adresse du serveur préremplie. Le fichier servi fait donc quelques dizaines d'octets de plus que le `size` annoncé par la liste.
* **Réglages :** `RELEASE_REPO=off` coupe la source GitHub (serveur sans accès Internet) ; `RELEASE_REPO=<proprietaire>/<depot>` en désigne une autre. `DOWNLOADS_DIR` (par défaut `/app/downloads`) reste un dossier d'installeurs posés à la main (envoi par l'administrateur, volume) : un fichier qui s'y trouve l'emporte sur la Release pour sa plateforme.
* **Publiques (sans authentification) :** c'est par là qu'un nouvel utilisateur récupère l'app avant d'avoir un compte, et un téléchargement navigateur ne peut pas porter d'en-tête `Authorization`.
* **Réponse (JSON) :** `{"artifacts": [{"platform": "macos", "label": "macOS", "file": "Onyx-1.0.0-macos.dmg", "url": "/api/downloads/Onyx-1.0.0-macos.dmg", "version": "1.0.0", "size": 43374616, "built_at": "2026-08-12T10:08:14Z"}]}`
* **Côté client :** la section « Applications » de l'écran Paramètres liste ce que le serveur propose. Elle disparaît d'elle-même si le serveur n'a aucun installeur à proposer (Release introuvable et rien dans le cache).

#### D'où viennent les fichiers

Le workflow `release.yml` construit les installeurs sur trois systèmes (Flutter ne cross-compile pas le desktop), les joint à la Release `v<version>` et publie l'image avec `--build-arg VERSION=<version>` : c'est cette version que le serveur annonce sur `/api/ping` et dont il cherche la Release. `publish-image.sh` / `.ps1` publient l'image seule ; elle n'aura d'installeurs à proposer que si la Release correspondante existe.
