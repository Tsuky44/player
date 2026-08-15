# ADR-0002 — Identification des médias et déduplication non destructive

- **Statut :** accepté
- **Date :** 2026-08-14
- **Portée :** indexeur (`server/indexer`). Le rendu côté application n'est pas modifié.

## Contexte

Sur une bibliothèque de production de 510 films, Onyx n'en affichait que 489, et une partie des
entrées pointait vers le mauvais film TMDB. Trois causes, chaînées :

1. **L'identité venait toujours du dossier parent.** `ResolveMovieLookupName` renvoyait le nom du
   dossier dès qu'un film n'était pas à la racine. `Films/Action/Inception.2010.mkv` était donc
   identifié comme « Action », et les trois fichiers de `Saga Harry Potter/` recevaient tous la
   même identité. Même défaut côté séries : `resolveShowTitleFromPath` retenait le dossier le
   **moins** profond, donc `Séries/Animes/Naruto/Saison 1/…` créait une série « Animes » qui
   avalait tous les animes de la bibliothèque.
2. **La déduplication supprimait ces doublons.** `dedupeDuplicateMovies` fusionnait toutes les
   lignes partageant un `tmdb_id`. Une fois un dossier entier identifié sous un seul titre, les
   fichiers disparaissaient de la base — d'où l'écart 510 → 489.
3. **L'année de sortie était mal extraite.** `extractYear` ne validait que la *première* occurrence
   d'un motif d'année et coupait le titre dessus : « Blade Runner 2049 (2017) » devenait
   « Blade Runner » sans année (2049 hors plage → rejeté), et « 1917 (2019) » produisait un titre
   vide, donc aucune recherche TMDB.

S'y ajoutaient des pertes silencieuses au parcours : `filepath.Walk` abandonnait tout le scan à la
première erreur d'E/S, les liens symboliques de dossiers n'étaient jamais suivis, et la liste
d'extensions ignorait `.m4v`, `.ts`, `.m2ts`, `.mpg`…

## Décision

### 1. Le dossier n'identifie un film que s'il lui appartient

Règle Emby : un dossier ne nomme le film que lorsqu'il ne contient qu'un seul film (les parties
`cd1`/`cd2` comptant pour une seule œuvre, les samples et bonus étant exclus du décompte). Sinon —
et pour tout dossier de regroupement reconnu (genre, lettre, qualité, langue, « Saga … », dossier
purement numérique) — l'identité vient du **nom de fichier**.

Pour les séries, le dossier retenu est le **plus profond** qui ne soit ni un dossier de saison, ni
un dossier de release, ni un dossier de regroupement.

### 2. L'année de sortie est choisie, pas devinée

`pickReleaseYear` retient d'abord une année entre parenthèses/crochets, sinon la **dernière**
occurrence plausible (1900 → année courante + 1), et ignore une année isolée en tête de nom (le
titre *est* l'année : « 1917 », « 2012 »). Le titre est coupé à cette position seulement, et les
nombres restants ne sont plus supprimés — « Blade Runner 2049 » garde son 2049.

### 3. Partager un `tmdb_id` ne justifie pas une suppression

`dedupeDuplicateMovies` ne supprime plus qu'une ligne réellement redondante : même chemin de
fichier qu'une autre ligne, ou fichier disparu alors qu'une copie vivante existe. Deux fichiers
distincts sur le même `tmdb_id` sont conservés (versions 1080p/4K) et signalés dans les logs.
`RedetectAmbiguousMovies` relance l'identification quand leurs noms de fichiers désignent des films
différents — c'est la signature d'une erreur d'appariement, et la bibliothèque se répare seule.

Corollaire : `ResolveCanonicalMovieID` ne redirige plus une ligne qui possède son propre fichier,
sans quoi l'ouverture d'une version renvoyait les détails — et le fichier — d'une autre.

### 4. Un scan ne perd rien en silence

Le parcours est tolérant aux erreurs (un dossier illisible n'interrompt plus rien), suit les liens
symboliques avec garde anti-boucle, et couvre les conteneurs vidéo courants. Le nettoyage des
fichiers disparus refuse de s'exécuter si une racine est injoignable ou si plus d'un quart de la
bibliothèque semble manquer — un NAS démonté ne doit pas vider le catalogue.

Chaque scan produit un **rapport** (`GET /api/indexer/report`) : fichiers vus, indexés, ignorés
avec le motif, et éléments sans correspondance TMDB. L'écart entre « fichiers sur le disque » et
« éléments dans l'app » devient vérifiable au lieu d'être supposé.

### 5. Réparation des bibliothèques déjà indexées

Un scan ignore les fichiers déjà connus : les lignes fautives ne se corrigeraient jamais seules.
`RelinkEpisodesToShows`, exécuté à chaque scan, recalcule série/saison depuis le chemin et
ré-attache les épisodes mal classés **en conservant leur `id`** (progression et sous-titres
préservés). Côté films, `POST /api/indexer/metadata/redetect-all` reste l'action manuelle.

## Conséquences

- Les seuils d'acceptation TMDB deviennent explicites : titre quasi identique sans année
  (≥ 0,92), titre proche avec année concordante (≥ 0,80), rejet dès que l'année diffère de plus
  d'un an. La similarité tient compte du titre original (un nom de release anglais retrouve une
  fiche française) et pondère l'inclusion par la longueur — « Alien » ne vaut plus autant pour
  « Aliens » que pour « Alien vs Predator ».
- Les images disque (`.iso`) ne sont plus indexées mais rapportées : illisibles en direct play,
  elles créaient des entrées mortes.
- Les dossiers `VIDEO_TS`/`BDMV` ne produisent plus un film par fragment `.VOB`.
- Le nombre d'appels TMDB par titre baisse (cache de recherche par scan, arrêt anticipé sur une
  correspondance exacte), ce qui compense le coût des variantes de requêtes.
