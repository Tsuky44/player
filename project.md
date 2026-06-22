# 🚀 Projet : Mon Serveur de Médias Personnalisé (Alternatif à Emby)

## 📌 Introduction et Vision du Projet
L'objectif est de concevoir un clone d'Emby privé, ultra-léger, performant et centré sur le **Direct Play pur à 100 %**. Le serveur Docker (Back-End Go) servira de base de données et de distributeur de fichiers brut. L'application Flutter (Front-End) gérera l'interface utilisateur et le décodage vidéo via **Media Kit (mpv)**. 

Le système gérera nativement les profils utilisateurs, la séparation stricte des contenus (Films vs Séries/Saisons/Épisodes), le suivi de la progression ("Vu", "En cours"), et un système de mise en cache asymétrique pour un lancement instantané des vidéos sans ralentir le serveur.

---

## 🛠 La Stack Technique & Dépendances

### Partie Serveur (Back-End)
* **Environnement :** Docker (pour l'isolation et la portabilité).
* **Langage :** Go (Golang) — Pour sa vitesse, sa gestion native et ultra-légère du streaming HTTP par morceaux (`http.ServeFile`) et sa consommation de RAM minimale (< 20 Mo).
* **Base de données :** SQLite — Légère et ultra-rapide, idéale pour stocker les métadonnées et la progression sans la lourdeur d'un serveur de BDD dédié.

**Dépendances Go indispensables :**
* `net/http` (Natif) : Gestion du serveur web et du streaming par morceaux (HTTP Range Requests).
* `modernc.org/sqlite` : Driver SQLite pur Go (facilite la compilation Docker sans dépendance C).
* `github.com/julienschmidt/httprouter` : Routeur HTTP ultra-rapide pour l'API.
* `golang.org/x/crypto/bcrypt` : Pour hacher proprement les mots de passe des profils utilisateurs.

### Partie Application (Front-End)
* **Framework :** Flutter (Dart) — Une seule base de code pour iOS, Android, macOS et Android TV / Apple TV.
* **Moteur Vidéo :** Media Kit (basé sur le lecteur open-source surpuissant `mpv`).

**Dépendances Flutter (`pubspec.yaml`) :**
* `media_kit`, `media_kit_video`, `media_kit_libs_video` : Le cœur du lecteur vidéo et ses codecs.
* `dio` : Client HTTP avancé (idéal pour envoyer régulièrement la progression de lecture en arrière-plan).
* `flutter_secure_storage` : Pour stocker le token de l'utilisateur (connexion automatique).
* `provider` ou `flutter_bloc` : Pour la gestion d'état globale (profil connecté, état du lecteur).

---

## 📋 Plan d'Action Étape par Étape

### PHASE 1 : Le Serveur (Back-End en Go)

* **Étape 1.1 : Structure de la Base de Données (SQLite)**
    * Créer les tables nécessaires pour gérer l'écosystème :
        * `users` : `id`, `username`, `password_hash`.
        * `medias` : `id`, `type` (film ou épisode), `title`, `file_path`, `duration`, `parent_id` (ID de la saison/série pour les épisodes), `poster_url`.
        * `progressions` : `user_id`, `media_id`, `current_position_seconds`, `is_finished`.
* **Étape 1.2 : L'Indexeur Intelligent (Scan de tes disques)**
    * Écrire le script en Go qui scanne tes dossiers Docker et sépare le contenu (ex: dossier `/Films/` vs dossier `/Series/`).
    * Parser les noms de fichiers pour les séries (ex: détecte `S01E03` pour lier automatiquement l'épisode à la bonne saison et à la bonne série en base de données).
* **Étape 1.3 : L'API d'Affichage et de Synchronisation**
    * Créer la route `GET /api/home` : Renvoie les sections de la page d'accueil pour l'utilisateur connecté (**"Reprendre la lecture"**, **"Films récents"**, **"Séries récentes"**).
    * Créer la route `POST /api/progress` : Reçoit le `media_id` et la position actuelle en secondes envoyés par l'application pour mettre à jour la table `progressions`.
* **Étape 1.4 : Le Distributeur de Chunks (Direct Play)**
    * Créer la route `GET /stream?media_id=...`. Elle utilise `http.ServeFile` qui écoute les requêtes HTTP de l'application et renvoie exactement les octets demandés (Range Requests).

---

### PHASE 2 : L'Application (Front-End en Flutter)

* **Étape 2.1 : Écran d'Accueil & Gestion des Profils**
    * Créer un écran de sélection de profil ou de connexion (à la Emby/Netflix).
    * Créer l'interface principale avec deux onglets ou sections bien distinctes : **Films** (grille de jaquettes) et **Séries** (cliquer sur une série affiche les saisons, puis les épisodes).
    * Afficher tout en haut de l'accueil le carrousel horizontal **"Reprendre la lecture"** avec une barre de progression visuelle sous chaque jaquette entamée.

* **Étape 2.2 : Configuration du Streaming Intelligent**
    * Lors de l'initialisation de `media_kit`, injecter les propriétés natives de `mpv` pour créer le comportement de cache asymétrique :
        ```dart
        // 1. Allumage Instantané : MPV demande un micro-chunk (1s de vidéo) pour afficher l'image tout de suite
        nativePlayer.setProperty('cache-secs', '1'); 
        
        // 2. Vitesse de croisière : Une fois lancé, MPV demande de gros blocs (50 Mo) pour remplir la RAM
        nativePlayer.setProperty('demuxer-max-bytes', '52428800'); 
        
        // 3. Anticipation : Autoriser le lecteur à bufferiser jusqu'à 2 minutes de film d'avance
        nativePlayer.setProperty('demuxer-readahead-secs', '120');
        ```
* **Étape 2.3 : Le Lecteur Customisé (Interface de Lecture)**
    * Créer une interface de lecteur épurée par-dessus la vidéo avec des widgets Flutter (`Stack`).
    * **Au lancement :** Demander au serveur si une progression existe. Si oui, afficher un pop-up *"Reprendre à XX:XX ?"* et utiliser `player.seek()` pour s'y rendre instantanément.
    * **Le Heartbeat (Pendant la lecture) :** Mettre en place un `Timer` qui envoie toutes les 10 secondes la position actuelle au serveur (`POST /api/progress`).
    * **Fonctionnalités de base attendues :** Boutons Play/Pause géants, double-clic pour avancer/reculer de 10 secondes, bouton de verrouillage de l'écran (mobile), et un menu customisé pour changer de piste audio ou afficher les sous-titres intégrés au fichier MKV.
    * **À la fermeture :** Si l'utilisateur quitte à plus de 90% du film, envoyer le statut `is_finished = true` pour marquer le média comme "Vu" et le retirer de la section "Reprendre la lecture".

---

## ⚡ Conseils d'Optimisation du Direct Play (Zéro Perte de Qualité)

1.  **Activer le mode WAL sur SQLite :**
    Puisque ton application va envoyer sa position de lecture toutes les 10 secondes (le Heartbeat), ta base de données va recevoir beaucoup d'écritures. En Go, active le mode **WAL** (`PRAGMA journal_mode=WAL;`). Cela permet d'écrire en base de données de manière ultra-rapide sans jamais bloquer l'affichage des jaquettes sur l'application.
2.  **Forcer le Décodage Matériel (GPU Client) :**
    Passe l'argument `--hwdec=auto` à `mpv` via `media_kit`. C'est le secret pour que ton téléphone ou ta TV lise un fichier 4K HDR brut sans faire ramer son processeur et sans solliciter ton serveur Docker.
3.  **Le saut temporel instantané (Seek Rapide) :**
    Pour que la reprise de lecture ou les sauts en avant soient instantanés, configure `media_kit` en mode `exact: false` pendant que l'utilisateur glisse son doigt sur la barre de progression, puis repasse en `exact: true` lorsqu'il lâche. Le lecteur trouvera l'image clé la plus proche en un clin d'œil.