# ADR-0018 — Surveillance de la médiathèque : scans ciblés au lieu de scans complets

- **Statut :** accepté
- **Date :** 2026-09-14
- **Portée :** serveur (`server/indexer`, démarrage dans `server/main.go`). L'app n'est pas
  modifiée.

## Contexte

Un fichier déposé dans la médiathèque n'apparaissait qu'au scan suivant, lancé au démarrage du
serveur ou à la main. Et un scan traitait toujours la bibliothèque entière :

- il listait chaque dossier et lisait les informations de chaque fichier vidéo, puis relisait une
  seconde fois celles de chaque fichier en base pour le nettoyage — deux passes complètes sur le
  disque, très lentes sur un partage réseau ;
- la détection du générique relançait toutes les saisons dont un épisode n'avait pas de marqueurs.
  Or c'est le cas le plus courant (ni IntroDB ni les chapitres ne trouvent rien) : ces épisodes
  étaient réanalysés à chaque scan, avec un appel IntroDB et un ffprobe chacun ;
- de même, un fichier qu'ffprobe ne sait pas lire était relu à chaque scan ;
- le nettoyage des saisons et séries vides relisait toute la table une fois **par épisode
  supprimé**.

Sur une grosse bibliothèque, ajouter un épisode coûtait donc plusieurs minutes d'E/S et de
nombreux appels réseau.

## Décision

### 1. Un moniteur tient la carte des dossiers et ne scanne que ce qui change

`indexer/monitor.go` garde en mémoire la liste des dossiers de la médiathèque, avec leur date de
modification et leurs sous-dossiers. Il l'apprend pendant le scan de démarrage, sans parcourir le
disque une seconde fois. Il détecte les changements de deux façons complémentaires :

- **Notifications du système de fichiers** (inotify sous Linux, via `fsnotify`) : un fichier
  est indexé quelques secondes après son arrivée. Elles coûtent une surveillance du noyau par
  dossier et ne voient pas les modifications faites par une autre machine sur un partage NFS/SMB.
- **Vérification périodique des dates de modification des dossiers** (toutes les 5 minutes par
  défaut) : ajouter, supprimer ou renommer une entrée change la date de son dossier, sur disque
  local comme sur NFS et SMB. Une seule lecture d'informations par dossier, sans le lister ni lire
  ses fichiers, suffit donc à trouver les dossiers modifiés. C'est le filet de sécurité pour tout
  ce que les notifications ne voient pas.

Un dossier modifié est scanné **en surface** : ses propres fichiers, un scan complet des
sous-dossiers qui n'existaient pas encore, et un nettoyage de ceux qui ont disparu. Les
événements sont regroupés (3 s de calme, 1 min au plus) pour qu'une copie en cours ne déclenche
pas un scan par écriture.

Les scans ciblés et le scan complet passent par le même verrou (`scanRun`) : un fichier ne peut
pas être indexé deux fois par deux scans simultanés.

### 2. Un fichier n'est indexé qu'une fois sa copie terminée

Rien sur le disque n'indique qu'une copie est finie. Un nouveau fichier est donc indexé quand deux
lectures espacées de 5 s voient la même taille et la même date de modification. Un fichier
modifié il y a plus de 2 minutes est accepté dès la première lecture : c'est un lien physique ou
un déplacement depuis le dossier de téléchargement (Sonarr, Radarr), complet par nature. Sans
cette attente, on enregistrerait la taille et l'analyse ffprobe d'un fichier à moitié écrit.

### 3. Le travail après indexation ne porte que sur ce qui vient d'arriver

Après un scan ciblé, une seule tâche de fond analyse les fichiers ajoutés ou modifiés avec
ffprobe, **un par un**, puis lance la détection du générique pour **ces seuls épisodes**. Une
saison entière arrivée d'un coup ne lance donc pas vingt ffprobe en parallèle.

Le scan ciblé ne relance ni la déduplication, ni le complément de métadonnées TMDB, ni la
détection sur toute la bibliothèque : ils restent attachés au scan complet.

### 4. Les tentatives sont mémorisées

La migration 8 ajoute à `medias` :

- `intro_checked_at` : quand la détection du générique a obtenu une réponse (même « rien »). Un
  épisode vérifié est ignoré pendant 30 jours, ce qui laisse à IntroDB le temps de se remplir. Une
  source en échec (IntroDB injoignable, ffprobe impossible) ne marque pas l'épisode ;
- `probe_failed_at` : quand ffprobe a échoué sur un fichier **présent**. Le fichier est ignoré
  pendant 7 jours. Un partage démonté ne compte pas comme un échec.

Les deux marques sont effacées quand le fichier change. La relance manuelle de la détection
(`DetectShowIntroOutro`) ignore toujours la première.

### 5. Le scan complet profite des mêmes économies

- le nettoyage ne relit plus que les fichiers en base que le parcours n'a **pas** vus ;
- le nettoyage des saisons et séries vides tourne une fois par passe, et non plus une fois par
  épisode supprimé.

### 6. Les garde-fous du nettoyage s'appliquent aux scans ciblés

Un partage démonté ressemble, depuis le conteneur, à un dossier dont le contenu a disparu. Un
scan ciblé ne supprime donc rien si la racine de la bibliothèque est inaccessible ou vide, ni plus
d'un quart de la bibliothèque en une passe.

## Configuration

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `LIBRARY_WATCH` | `true` | Active les notifications du système de fichiers. |
| `LIBRARY_POLL_INTERVAL` | `5m` | Intervalle de la vérification périodique ; `0` la désactive. |

L'état du moniteur est exposé dans `GET /api/indexer/status`, sous `library_monitor`.

## Conséquences

- Un épisode ou un film déposé dans la médiathèque apparaît en quelques secondes avec les
  notifications, et au plus en un intervalle de vérification sans elles. Aucun scan manuel n'est
  nécessaire.
- Le scan de démarrage reste un scan complet. Il rattrape ce qui a changé pendant que le serveur
  était arrêté.
- Sous Linux, chaque dossier surveillé consomme une surveillance inotify. Les noyaux récents en
  autorisent largement assez, mais un noyau ancien peut plafonner à 8 192. Le moniteur le signale
  dans les logs et laisse alors la vérification périodique couvrir les dossiers restants. On
  relève la limite sur l'hôte avec `sysctl fs.inotify.max_user_watches=524288`.
- Renommer un fichier ou un dossier le supprime puis le réindexe, et sa progression de lecture est
  perdue. C'était déjà le cas avec le scan complet.
- La vérification périodique lit les informations de chaque dossier à chaque passe (par paquets
  de 200, avec une courte pause entre deux). Sur un partage réseau très lent, on peut espacer
  `LIBRARY_POLL_INTERVAL`.
