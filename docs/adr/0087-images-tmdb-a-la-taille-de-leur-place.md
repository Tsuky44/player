# ADR-0087 — Les images TMDB se téléchargent à la taille de leur place, et la cascade d'arrivée saute en mode léger

- **Statut :** accepté
- **Date :** 2026-10-28
- **Portée :** `app/lib/utils/poster_url.dart` (`tmdbUrlForWidth`, `detailBackdropUrl`), `app/lib/widgets/global/app_network_image.dart`,
  `app/lib/widgets/global/staggered_entrance.dart`, l'onglet Demander et « Mes demandes »
  (`app/lib/screens/requests/`). Prolonge l'ADR-0086.

## Contexte

L'onglet Demander reprend l'interface d'OnyxHub : affiches seules, pastille de statut, cartouche au
survol, arrivée des cartes en cascade. OnyxHub a aussi allégé ses vignettes : `w342` au lieu de `w500`
pour une carte de grille.

Côté Onyx, chaque carte demandait `w500` pour que la même affiche ait la même URL sur tous les
écrans. Or une carte de grille se dessine sur 112 px logiques en téléphone (336 px physiques) ou
150 px sur un téléviseur à densité 1. Mesuré sur image.tmdb.org pour une même affiche : `w154`
14 Ko, `w342` 58 Ko, `w500` 117 Ko. Le décodage, ce qui fait saccader un petit téléviseur pendant
un défilement, coûte en proportion des pixels de la source. TMDB sert chacune de ses largeurs
(`w92` à `w1280`) pour n'importe quelle image, quelle que soit sa catégorie.

## Décision

- **`AppNetworkImage` descend toute URL TMDB en `w…` ou `original` à la plus petite largeur TMDB
  qui couvre la place physique de l'image** (`tmdbUrlForWidth`). La taille que demande l'appelant
  (`cardPosterUrl` → `w500`, `backdropImageUrl` → `w1280`) devient un plafond. Les logos décodés à
  la taille source et les tailles en `h…` ne bougent pas.
- **Le fond d'une fiche (bibliothèque et demande) est plafonné à `original`** (`detailBackdropUrl`),
  comme sur OnyxHub : sur une fenêtre de 2000 px, `w1280` était agrandi et se voyait flou. Il
  redescend à `w1280` dès que la place le permet. Les bandeaux qui tournent (accueil) et les fonds
  de collection ou de personne restent plafonnés à `w1280` : une image qui change toutes les
  quelques secondes ne doit pas coûter un décodage 4K.
- **En mode léger, jamais d'`original`** : `w1280` au plus, quelle que soit la place.
- **Le widget et `AppNetworkImage.precache` passent par la même fonction** (`_sourceFor`) : un
  préchauffage remplit l'entrée que la carte lira.
- **Une source plus étroite que la largeur de décodage arrondie se décode telle quelle**, au lieu
  d'être agrandie en mémoire.
- **En mode léger, le filtrage des images passe en bilinéaire** : elles sont déjà décodées à leur
  taille d'affichage, les mipmaps n'apportent rien.
- **La cascade d'arrivée** (`StaggeredEntranceScope`) a une seule horloge pour toute la grille, ne
  joue que sur les premières cartes, sans échelle ni flou. **Elle saute entièrement en mode léger**
  et sous « réduire les animations ». Contredit l'ADR-0086, qui garde les fondus en mode léger,
  parce qu'une cascade, ce sont une vingtaine de calques d'opacité ouverts ensemble : l'Apple TV HD
  ne les tient pas. Les fondus d'un seul élément restent.
- **Les animations sans fin** (pastille « en cours » qui respire, barre sous « En cours ») ne
  touchent que l'opacité ou une translation, dans leur propre calque, et disparaissent en mode léger.

## Conséquences

- Une même affiche peut avoir deux entrées sur disque : `w342` pour la carte, `w500` pour l'en-tête
  de la fiche. La fiche la télécharge une fois de plus, contre une grille entière deux à huit fois
  plus légère. La transition de lancement (`poster_launch_route.dart`) décode à la largeur de la
  carte : elle retombe en général sur l’URL de la carte et la dessine depuis la mémoire.
- Sur un écran dense (téléphone à densité 3, Retina), la carte reste en `w342` ou `w500` : rien ne
  devient flou.
- `image_url_sizing_test.dart` épingle l'échelle des tailles, `request_catalog_card_test.dart`
  l'URL qu'une carte télécharge et la cascade absente en mode léger.
