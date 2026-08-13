# 🚀 Onyx — Serveur Média (Back-End Go)

Un serveur multimédia ultra-léger (alternative moderne à Emby/Plex) écrit en Go, conçu exclusivement pour du **Direct Play pur à 100 %**, avec une consommation de RAM minimale (inférieure à 20 Mo) et des performances exceptionnelles.

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

---

## 📡 Documentation de l'API REST

Toutes les routes API (sauf l'inscription/connexion et le stream) requièrent l'en-tête HTTP d'authentification suivant :
`Authorization: Bearer <votre_token_de_session>`

### 🔑 1. Authentification

#### ➡️ Inscription
* **Route :** `POST /api/auth/register`
* **Corps (JSON) :**
  ```json
  {
    "username": "mon_pseudo",
    "password": "mon_super_mot_de_passe"
  }
  ```

#### ➡️ Connexion
* **Route :** `POST /api/auth/login`
* **Corps (JSON) :** identique à l'inscription.
* **Réponse (JSON) :**
  ```json
  {
    "token": "45d17ff25988ba97b819...",
    "user": { "id": 1, "username": "mon_pseudo" }
  }
  ```

#### ➡️ Profil connecté
* **Route :** `GET /api/auth/me`
* **Réponse (JSON) :**
  ```json
  { "id": 1, "username": "mon_pseudo" }
  ```

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

#### ➡️ Lancer un scan de la bibliothèque
* **Route :** `POST /api/indexer/scan`
* **Comportement :** Lance un scan de dossiers asynchrone (en arrière-plan) et renvoie immédiatement un accusé de réception.
* **Réponse (JSON) :** `{"status": "success", "message": "Scan triggered in background"}`

#### ➡️ Récupérer l'état du scan
* **Route :** `GET /api/indexer/status`
* **Réponse (JSON) :** `{"is_scanning": true/false}`

---

### 🎬 5. Lecture Vidéo (Direct Play)

* **Route :** `GET /stream?media_id=12`
* **Note importante :** Cette route est publique et ne nécessite pas d'en-tête de session pour garantir une compatibilité maximale à 100 % avec les lecteurs vidéo de tous les OS (Flutter, ExoPlayer, VLC, mpv) qui peinent parfois à injecter des en-têtes d'autorisation HTTP personnalisés lors de la diffusion en continu.
* **Comportement :** Émet des Range Requests. Supporte le streaming par morceaux, le multi-pistes, le chargement des sous-titres intégrés et les seeks fluides.

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
