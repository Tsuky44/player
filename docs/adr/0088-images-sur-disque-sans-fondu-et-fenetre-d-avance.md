# ADR-0088 — Une image déjà sur disque se pose sans fondu, et les listes d'images construisent une fenêtre d'avance

- **Statut :** accepté
- **Date :** 2026-10-28
- **Portée :** `app/lib/services/app_image_cache.dart` (index disque), `app/lib/widgets/global/app_network_image.dart`,
  `app/lib/utils/responsive.dart` (`AppLayout.imageCacheExtent`), chaque liste paresseuse qui dessine des
  images. Prolonge l'ADR-0087.

## Contexte

Objectif posé : qu'une affiche ou une image TMDB s'affiche « en 1 ms ». Une image passe par trois
chemins, au coût très différent :

- **Mémoire** (cache d'images décodées de Flutter) : servie de façon synchrone, sur l'image même où
  le widget la demande, sans fondu. C'est déjà le cas, et le seul chemin qui tienne réellement la
  milliseconde.
- **Disque** (`flutter_cache_manager`) : recherche dans l'index, lecture du fichier, décodage hors du
  fil principal, quelques millisecondes à quelques dizaines. Mais `CachedNetworkImage` traitait ce
  chargement comme un téléchargement et posait l'image en fondu de 180 ms : à chaque ouverture de
  l'app, chaque affiche semblait arriver du réseau.
- **Réseau** : un aller-retour vers image.tmdb.org, incompressible. On ne peut que le commencer plus
  tôt.

Et une carte ne demandait son image qu'en entrant à l'écran : Flutter ne construit que 250 px hors
champ, moins d'une rangée d'affiches.

## Décision

- **`AppImageCache` tient un index synchrone des URL présentes sur disque.** Il se charge au
  démarrage en une requête (`loadDiskIndex`, sans attendre : la première image ne patiente pas
  derrière lui) et se met à jour à chaque fichier servi, retiré ou au vidage du cache, par une
  sous-classe du gestionnaire.
- **`AppNetworkImage` pose sans fondu une image dont l'URL est dans l'index.** Le fondu ne reste que
  pour ce qui vient vraiment du réseau.
- **Chaque liste paresseuse qui dessine des images construit une fenêtre entière d'avance de chaque
  côté** (`scrollCacheExtent: AppLayout.imageCacheExtent(context)`, soit
  `ScrollCacheExtent.viewport(1)`). Le téléchargement et le décodage partent une fenêtre avant que la
  carte n'arrive : elle se dessine depuis la mémoire.
- **En mode léger, la marge reste celle de Flutter** : sur une Apple TV HD, des dizaines d'affiches
  décodées en plus disputeraient la mémoire au décodeur vidéo (ADR-0086).

## Conséquences

- Une image vue lors d'une session précédente s'affiche dès qu'elle est décodée, sans animation ; une
  image en mémoire, sur l'image même. Le premier affichage d'une image jamais téléchargée reste borné
  par le réseau : aucune optimisation côté client ne le ramène à 1 ms.
- Une fenêtre d'avance, c'est environ deux fois plus de cartes construites. Sur un téléphone en grille
  de trois colonnes, une vingtaine d'affiches décodées en plus (environ 15 Mo), dans le plafond du
  cache d'images.
- Le nettoyage par capacité du paquet ne passe pas par l'index : une entrée peut survivre à son
  fichier. Le seul effet est une image réseau qui arrive sans fondu, jamais une image manquante.
- `image_cache_extent_guard_test.dart` refuse une liste paresseuse sans `scrollCacheExtent` hors du
  lecteur et des réglages, avec une liste blanche justifiée. `image_disk_hit_fade_test.dart` épingle
  le fondu absent sur disque et présent depuis le réseau.
