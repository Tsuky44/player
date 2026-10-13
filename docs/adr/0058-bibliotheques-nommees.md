# ADR-0058 — Bibliothèques nommées : un dossier, un nom libre, autant qu'on en veut

- **Statut :** accepté. Le Go et le Dart sont testés ; les onglets n'ont pas encore été vus
  tourner dans l'app, ni essayés à la télécommande.
- **Date :** 2026-10-12
- **Portée :** `server/libraries`, la table `libraries`, `server/handlers/libraries.go`,
  `server/handlers/library.go`, `server/indexer/indexer.go`, `server/indexer/monitor.go`,
  `server/indexer/library_forget.go`, `server/indexer/plain_libraries.go`,
  `server/handlers/home_libraries.go`, `server/config/settings.go`,
  `app/lib/models/media_library.dart`, `app/lib/services/api/libraries.dart`,
  `app/lib/providers/library_provider.dart`, `app/lib/screens/library/library_screen.dart`,
  `app/lib/screens/shell/` (onglets), `app/lib/screens/settings/widgets/libraries_group.dart`.
- **Remplace :** les deux réglages `movies_dir` / `series_dir` de `/api/settings`
  ([ADR-0001](0001-user-permissions-and-invitations.md) les citait comme exemple de
  `manage_settings` ; le droit reste le même).
- **Prolonge :** [ADR-0018](0018-surveillance-de-la-mediatheque.md) (le moniteur suit désormais
  une liste de racines) et [ADR-0013](0013-plusieurs-serveurs-et-demandes-d-acces.md) (un serveur
  plus ancien reste lisible).

## Contexte

Le serveur connaissait exactement deux dossiers, « le dossier des films » et « le dossier des
séries », et l'app exactement deux onglets, « Films » et « Séries », écrits dans son code. Les
chemins par défaut de l'image étaient `/media/Films` et `/media/Series`.

Deux conséquences :

- on ne pouvait pas ranger autrement que le logiciel l'avait décidé — pas de bibliothèque
  « Animés », « Documentaires », « Vidéos de famille » ou « Concerts », pas de second dossier de
  films sur un autre disque ;
- le logiciel affirmait lui-même ce que son utilisateur y mettrait. Un lecteur de médias
  personnels n'a pas à nommer le contenu de la médiathèque de quelqu'un : c'est à l'administrateur
  du serveur de dire ce que sont ses dossiers, comme le font Emby, Jellyfin ou Plex.

## Décision

### 1. Une bibliothèque = un dossier, un nom, un type

La table `libraries` (migration 22) tient une ligne par bibliothèque : `name` (libre, 40
caractères au plus : il s'affiche dans un onglet), `path` (unique — un dossier ne sert qu'à une
bibliothèque) et `kind`, la façon de lire le dossier :

- `movies` : un fichier vidéo est un film, que le serveur identifie (affiche, fiche) ;
- `shows` : les fichiers sont des épisodes, rangés par série et par saison ;
- `other` : ni l'un ni l'autre — vidéos de famille, concerts, cours. Chaque vidéo est présentée
  sous le nom de son fichier, et le serveur ne cherche jamais à la reconnaître (§ 6).

Le type n'est pas un nom : c'est la règle de lecture de l'indexeur. Il se
choisit à la création et ne se change pas — des fiches lues comme des films ne deviennent pas des
épisodes ; on supprime la bibliothèque et on la recrée.

Il n'y a pas de limite au nombre de bibliothèques, ni de bibliothèque obligatoire. Un serveur neuf
démarre sans aucune, et c'est depuis l'app qu'on les déclare.

### 2. L'appartenance d'un média est son chemin

`medias` ne reçoit pas de colonne `library_id`. Un fichier appartient à la bibliothèque dont le
dossier le contient ; une série, à celles où se trouvent ses épisodes. Les listes se filtrent par
plage de chemins (`libraries.PathRange`, servie par `idx_medias_file_path`).

Une clé étrangère aurait demandé de rattacher tout le catalogue existant, de la tenir à jour à
chaque déplacement de dossier, et de décider de quelle bibliothèque est une série — qui n'a pas
de fichier à elle. Le chemin dit déjà tout cela, et reste juste quand on renomme la bibliothèque.

Conséquence assumée : deux bibliothèques emboîtées (`/media` et `/media/Animes`) listent toutes
deux les fichiers de la plus profonde. Pour l'indexation, un fichier revient à la plus profonde
(`rootFor`), comme l'ancien couple films/séries.

### 3. L'API

| Route | Droit | Rôle |
| --- | --- | --- |
| `GET /api/libraries` | compte connecté | Les bibliothèques, par ordre de création. `path` n'est joint que pour `manage_settings`. |
| `POST /api/libraries` | `manage_settings` | Crée une bibliothèque (`name`, `kind`, `path`) et lance une analyse. |
| `PUT /api/libraries/:id` | `manage_settings` | Renomme ou change de dossier (`name`, `path`). |
| `DELETE /api/libraries/:id` | `manage_settings` | Retire la bibliothèque et son catalogue. |
| `GET /api/movies?library=ID`, `GET /api/shows?library=ID` | compte connecté | La liste d'une bibliothèque. Sans paramètre : tout le serveur. |

La liste est lisible par tout compte parce que ce sont les onglets de l'app ; le dossier, lui, est
l'arborescence du disque du serveur et n'est envoyé qu'à qui peut la changer. Écrire reste
`manage_settings`, comme l'étaient les deux chemins : c'est faire lire un autre dossier du disque
au serveur.

Le dossier est vérifié à la saisie (chemin absolu, dossier existant) : une faute de frappe se dit
dans le formulaire, pas par une bibliothèque vide au scan suivant. Il n'est revérifié que s'il
change, pour qu'on puisse renommer une bibliothèque dont le disque est débranché.

Supprimer une bibliothèque, ou changer son dossier, retire du catalogue ce qui était indexé sous
l'ancien dossier (`indexer.ForgetMediaUnder`) — avec la progression de lecture de ces titres. Rien
d'autre ne le ferait : le nettoyage d'un scan ne retire que les fichiers disparus du disque, et
ceux-là y sont toujours. Les fichiers eux-mêmes ne sont jamais touchés.

Le serveur annonce la capacité `libraries` sur `/api/ping`.

### 4. L'indexeur et le moniteur suivent une liste

`indexer.ScanMedia` et `MonitorOptions.Roots` prennent la liste des bibliothèques au lieu de deux
chemins. Chaque dossier est parcouru selon son type. Le moniteur ne retient que le dossier et le
type : renommer une bibliothèque ne lui fait pas jeter sa carte des dossiers. Une bibliothèque
ajoutée est analysée tout de suite, et sinon vue par le moniteur à sa relecture de la liste
(une minute au plus).

Le rapport de scan garde ses deux sections `movies` et `series` : ce sont des cumuls par type, et
`root` y liste les dossiers.

### 5. L'app n'a que les onglets que le serveur liste

La coquille construit un onglet par bibliothèque, sous son nom, entre l'accueil et les demandes.
Les onglets sont désignés par un identifiant (`ShellTabs`) et non plus par un rang : une
bibliothèque ajoutée ne déplace l'état d'aucun autre onglet (`ShellTabStack` tient une clé globale
par identifiant).

- en-tête des grands écrans : les onglets défilent quand ils dépassent la place disponible, sans
  pousser la recherche ni le compte ;
- téléphone : jusqu'à deux bibliothèques, un onglet chacune ; au-delà, un onglet
  « Bibliothèques » ouvre leur liste.

Un seul écran, `LibraryScreen`, remplace `MoviesScreen` et `ShowsScreen`. Réglages → Bibliothèque
liste les bibliothèques et permet d'en ajouter, de les renommer, de changer leur dossier et de les
supprimer.

### 6. Le type « autre » : des vidéos que le serveur n'identifie pas

Une vidéo d'une bibliothèque `other` est rangée comme un film sans identité (`type = 'movie'`,
`tmdb_id` à 0, titre = nom du fichier) : la lecture, la progression, les téléchargements et la
grille la traitent comme n'importe quel film, sans cas particulier.

Ce qui la distingue est ce que le serveur ne lui fait pas. Tout ce qui rattrape un film sans
identité passe par `indexer/plain_libraries.go` pour la laisser tranquille : l'identification à
l'indexation, le complément des fiches, la réidentification de tout le catalogue, la file des
« médias à vérifier », et l'identification à la volée qu'ouvrir une fiche déclenchait. Sans cela,
un film de vacances nommé « Noël 2019 » recevrait l'affiche du premier film « Noël » de TMDB.

Une action demandée à la main par un administrateur sur une vidéo précise (« corriger la fiche »)
reste possible : c'est son choix.

Une telle vidéo n'a pas d'affiche : sa carte montre le visuel par défaut.

### 7. Les rangées de l'accueil portent le nom des bibliothèques

`GET /api/home` ajoute `libraries` : une rangée par bibliothèque qui contient quelque chose, avec
son `id`, son `name`, son `kind` et ses derniers ajouts (`items`). L'app en fait ses rangées
« Derniers ajouts · *nom* », et « Tout voir » ouvre l'onglet de la bibliothèque.

`recent_movies` et `recent_shows` restent dans la réponse pour les apps plus anciennes ; une app
à jour ne les affiche que face à un serveur qui n'envoie pas `libraries`.

## Compatibilité

- **Installation existante.** La migration 22 crée, une fois, « Films » et « Séries » à partir de
  ce que le serveur lisait : le réglage `movies_dir` / `series_dir`, sinon `MOVIES_DIR` /
  `SERIES_DIR`, sinon le dossier par défaut de l'image s'il existe. Le catalogue, la progression
  et les identifiants ne changent pas. Ces deux bibliothèques se renomment et se suppriment comme
  les autres. `MOVIES_DIR` et `SERIES_DIR` ne servent plus qu'à cette reprise.
- **Serveur neuf.** L'image pose `MOVIES_DIR` et `SERIES_DIR` pour tout le monde : les reprendre
  donnerait à chaque installation deux bibliothèques « Films » et « Séries » que personne n'a
  demandées. L'environnement et le dossier par défaut ne sont donc repris que si le catalogue
  contient déjà des fichiers. Un serveur neuf démarre sans bibliothèque ; l'accueil de l'app
  mène son administrateur à « Ajouter une bibliothèque ». Un dossier enregistré dans les réglages
  est, lui, toujours repris.
- **App à jour, serveur plus ancien** (ADR-0013). Sans la capacité `libraries`, l'app présente les
  deux listes du serveur comme deux bibliothèques non modifiables (`MediaLibrary.legacy`), et la
  page de réglages invite à mettre le serveur à jour.
- **App plus ancienne, serveur à jour.** `/api/movies` et `/api/shows` sans paramètre rendent
  toujours tout le serveur. `/api/settings` ne porte plus `movies_dir` / `series_dir` : l'ancienne
  page de réglages affiche deux champs vides et les enregistrer est sans effet.

## Conséquences

- Les mots « Films » et « Séries » ne nomment plus aucune bibliothèque ni aucune rangée dans le
  code : ils restent comme libellés du type à la création d'une bibliothèque, comme noms des deux
  bibliothèques reprises d'une installation existante, et face à un serveur plus ancien.
- La rangée « à découvrir » et le bandeau de l'accueil restent tirés de tout le serveur, parmi
  les titres qui ont une affiche : les vidéos d'une bibliothèque « autre » n'y figurent pas.
- Les droits ne distinguent pas les bibliothèques : tout compte voit toutes les bibliothèques.
  Restreindre une bibliothèque à certains comptes demanderait de filtrer chaque route qui rend un
  média, pas seulement les listes.
- Pas d'explorateur de dossiers dans l'app : le chemin se tape, et le serveur dit s'il existe.
