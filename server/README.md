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

Les sous-titres extraits et les aperçus de la barre de lecture sont rangés à côté de la base. Le journal s'écrit en texte sur la sortie d'erreur ; `LOG_FORMAT=json` donne une ligne JSON par entrée, et `LOG_LEVEL` (`debug`, `info`, `warn`, `error`) règle ce qui est écrit.

---

## 📡 Documentation de l'API REST

Toutes les routes API (sauf l'inscription/connexion et le stream) requièrent l'en-tête HTTP d'authentification suivant :
`Authorization: Bearer <votre_token_de_session>`

### 🔑 1. Authentification

#### ➡️ Inscription
* **Route :** `POST /api/auth/register`
* **L'inscription libre est fermée.** Elle n'aboutit que dans deux cas : la base n'a encore aucun
  compte (ce premier compte devient le **propriétaire** et reçoit tous les droits), ou un token
  d'invitation valide est fourni.
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
* **Corps (JSON) :** `username` + `password`.
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
      "invite_grants": { "request_media": true }
    }
  }
  ```

#### ➡️ Profil connecté
* **Route :** `GET /api/auth/me` — même charge utile que `user` ci-dessus.

#### ➡️ Changer son mot de passe
* **Route :** `POST /api/auth/password`
* **Corps (JSON) :** `{ "current_password": "…", "new_password": "…" }`

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

---

### 🏠 2. Accueil & Progression

#### ➡️ Page d'Accueil (Dashboard)
* **Route :** `GET /api/home`
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

---

### 📂 3. Navigation Bibliothèque

#### ➡️ Liste des Films
* **Route :** `GET /api/movies`
* **Réponse (JSON) :** Liste complète de tous les films avec la progression de l'utilisateur connecté sous chaque film (si commencée).

#### ➡️ Liste des Séries
* **Route :** `GET /api/shows`
* **Réponse (JSON) :** Liste des séries TV indexées.

#### ➡️ Liste des Saisons d'une Série
* **Route :** `GET /api/shows/:id/seasons`

#### ➡️ Liste des Épisodes d'une Saison
* **Route :** `GET /api/seasons/:id/episodes`
* **Réponse (JSON) :** Liste complète des épisodes de la saison avec l'état de progression/lecture associé à chaque épisode pour l'utilisateur connecté.

---

### 🔄 4. Indexation & Scan

#### ➡️ Surveillance automatique
* **Comportement :** Le serveur surveille les dossiers Films et Séries. Un fichier déposé (nouveau film, nouvel épisode) est indexé en quelques secondes, et un fichier supprimé est retiré, sans scan manuel. Seul le dossier modifié est scanné.
* **Configuration :** `LIBRARY_WATCH` (`true` par défaut) active les notifications du système de fichiers ; `LIBRARY_POLL_INTERVAL` (`5m` par défaut, `0` pour désactiver) règle la vérification périodique des dossiers, qui rattrape ce que les notifications ne voient pas sur un partage réseau. Détails : `docs/adr/0018-surveillance-de-la-mediatheque.md`.

#### ➡️ Lancer un scan de la bibliothèque
* **Route :** `POST /api/indexer/scan`
* **Comportement :** Lance un scan de dossiers asynchrone (en arrière-plan) et renvoie immédiatement un accusé de réception.
* **Réponse (JSON) :** `{"status": "success", "message": "Scan triggered in background"}`

#### ➡️ Récupérer l'état du scan
* **Route :** `GET /api/indexer/status`
* **Réponse (JSON) :** `{"is_scanning": true/false, …, "library_monitor": {"running": true, "notifications": true, "folders": 1234, "pending_folders": 0, "pending_files": 0, …}}`

---

### 🎬 5. Lecture Vidéo (Direct Play)

* **Route :** `GET /stream?media_id=12&ticket=…`
* **Note importante :** Pas d'en-tête de session, parce que les lecteurs vidéo (ExoPlayer, mpv, AVPlayer) injectent mal les en-têtes personnalisés. L'accès passe par un ticket de lecture temporaire dans l'URL (`POST /api/playback/tickets`), voir `docs/playback-tickets.md`.
* **Comportement :** Émet des Range Requests. Supporte le streaming par morceaux, le multi-pistes, le chargement des sous-titres intégrés et les seeks fluides.

#### ➡️ Transcodage (HLS)
* **Configuration :**
  * `MAX_TRANSCODES` : nombre maximal de sessions simultanées (par défaut la moitié des cœurs, au moins 4 ; `0` retire la limite). Au-delà, `/start` répond 503 avec `Retry-After`.
  * `HLS_DIR` : dossier de travail des sessions (par défaut `onyx-hls` dans le dossier temporaire du système). Les sessions laissées par un arrêt brutal y sont effacées au démarrage.
  * `HLS_MIN_FREE_MB` : espace libre minimal sur ce dossier pour ouvrir une session (`2048` par défaut, `0` pour désactiver).
  * `HLS_RETAIN_MINUTES` : ce qu'une session garde derrière la lecture quand le client sait rouvrir une session pour reculer plus loin (`30` par défaut). Les clients plus anciens gardent toute leur session.
* **Comportement :** une seule session par ticket de lecture. Celle que remplace une nouvelle session (saut, changement de qualité) est arrêtée trente secondes plus tard si le client ne l'a pas fait lui-même.

---

### 🔗 5 bis. Liens de partage publics

Un film ou un épisode partagé par un lien qui s'ouvre sans compte, dans un navigateur :
`https://serveur/share#<code>`. Le code est dans le fragment, que le navigateur n'envoie jamais :
il ne finit dans aucun journal. Décisions détaillées : `docs/adr/0037-liens-de-partage-publics.md`.

Côté créateur (`share_media`) :

* `POST /api/shares` — corps `{"media_id": 42, "password": "", "single_use": true, "expires_in_hours": 168}`.
  `expires_in_hours` vaut `0` (sans échéance), `24`, `168` ou `720`. Répond `201` avec le lien et son
  `code`, rendu **cette fois seulement** : le serveur n'en garde que l'empreinte SHA-256.
* `GET /api/shares` — ses liens, avec leur `status` : `active`, `expired` ou `watched`.
* `DELETE /api/shares/:id` — supprime le lien et coupe aussitôt les lectures qu'il a ouvertes.

Retirer `share_media` à un compte supprime ses liens.

Côté visiteur, sans compte — le code voyage dans le corps JSON :

* `GET /share` — la page de lecture (HTML + JS, hls.js chargé depuis cdnjs).
* `POST /api/shared/info` `{"code", "viewer"}` — faut-il un mot de passe ; le média n'est décrit
  qu'une fois le mot de passe donné. `404` inconnu, `410` expiré ou vu, `409` réservé ailleurs.
* `POST /api/shared/open` `{"code", "password", "viewer"}` — délivre un ticket de lecture au nom du
  lien, et le jeton `viewer` du navigateur. Un lien à usage unique est réservé par ce navigateur.
  Limité comme la connexion, par adresse et par lien.
* `POST /api/shared/renew` `{"code", "viewer", "ticket"}` — prolonge le ticket (toutes les 5 min).
* `POST /api/shared/progress` `{"code", "viewer", "ticket", "position_seconds"}` — au seuil « vu »
  (90 %), un lien à usage unique est détruit (`{"consumed": true}`). Le navigateur qui l'a vu peut
  encore renouveler son ticket pendant une heure, le temps du générique.
* `POST /api/shared/close` `{"code", "ticket"}` — révoque le ticket à la fermeture de la page.

Le ticket ouvre ensuite les routes HLS habituelles (`/api/v1/stream/…?ticket=…`). La page ne
déclare aucune capacité : elle reçoit du H.264 + AAC stéréo en MPEG-TS. Un lien tient au plus
quatre lectures simultanées.

---

### 📥 6. Téléchargement des applications clientes

* **Routes :** `GET /api/downloads` · `GET /api/downloads/:fichier`
* **Comportement :** Publie les applications installables (APK Android, DMG macOS, EXE Windows) embarquées dans l'image Docker sous `/app/downloads`. La liste est construite en scannant le dossier, il n'y a donc aucun manifeste à maintenir. Le fichier est servi en `attachment` avec support des Range Requests (une reprise après coupure ne repart pas de zéro).
* **Publiques (sans authentification) :** c'est par là qu'un nouvel utilisateur récupère l'app avant d'avoir un compte, et un téléchargement navigateur ne peut pas porter d'en-tête `Authorization`.
* **Réponse (JSON) :** `{"artifacts": [{"platform": "macos", "label": "macOS", "file": "Onyx-1.0.0-macos.dmg", "url": "/api/downloads/Onyx-1.0.0-macos.dmg", "version": "1.0.0", "size": 43374616, "built_at": "2026-08-12T10:08:14Z"}]}`
* **Côté client :** la section « Applications » de l'écran Paramètres liste ce que le serveur propose. Elle disparaît d'elle-même si aucun artefact n'est embarqué.

#### Comment les fichiers arrivent dans l'image

Flutter ne cross-compile pas les cibles desktop : **un Mac produit le DMG et l'APK, une machine Windows produit l'EXE et l'APK, aucune machine ne produit les trois**. `publish-image.sh` (et `publish-image.ps1`) contournent ça en trois temps :

1. récupération des artefacts déjà publiés depuis l'image `:latest` (`docker create` + `docker cp`) — l'image précédente sert de stockage entre les machines de build ;
2. build local optionnel (`scripts/build-releases.sh`, mode auto selon l'OS) puis staging via `scripts/stage-downloads.sh`, qui renomme en `Onyx-<version>-<plateforme>.<ext>` et remplace l'artefact précédent de cette plateforme ;
3. `docker buildx build --push`, le `COPY downloads/` du Dockerfile embarquant le tout.

Conséquence : publier depuis le Mac met à jour le DMG et l'APK **sans perdre** l'EXE publié depuis Windows, et inversement. Répondre `n` à la question du build conserve simplement les artefacts de la publication précédente.
