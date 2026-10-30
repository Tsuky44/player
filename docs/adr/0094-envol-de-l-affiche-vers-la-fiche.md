# ADR-0094 — L'envol de l'affiche vers la fiche

- **Statut :** accepté. Le rendu n'a pas été mesuré sur une Apple TV HD ni sur un PC modeste (voir
  « À vérifier »).
- **Date :** 2026-10-30
- **Portée :** `widgets/global/poster_flight.dart`, `screens/requests/request_detail_launch.dart`,
  `request_detail_screen.dart`, `widgets/request_media_card.dart`, et le survol de `poster_card.dart`
  (zoom de l'image, lignes du cartouche). Contredit l'ADR-0086 sur un point : la durée de ce seul
  trajet (1,37 s) sort de la plage de 180 à 280 ms d'`AppMotion`.

## Contexte

Entre le survol d'une affiche et l'arrivée sur sa fiche, MediaHub joue une suite de mouvements : zoom
de l'image, titre, type et résumé qui montent l'un après l'autre, fond préchargé, puis au clic la carte
qui se soulève, se retourne sur le fond de la fiche, fonce à sa place en s'étirant, s'écrase, rebondit
et se pose pendant que les textes tombent. Onyx n'avait que le zoom de la carte et le cartouche, puis
une route ordinaire.

Le budget fixé : ne pas coûter plus de quelques pour cent de ressources sur un PC modeste ou une TV peu
puissante.

## Décision

- **L'envol est la transition d'une route** (`PosterFlightRoute`, un `PageRoute`). Une horloge, celle
  de la route, pilote tout. Flutter la rend opaque à la fin et met l'ancienne page hors écran : aucune
  `OverlayEntry`, aucun second contrôleur.
- **Un seul élément en mouvement** : l'image (affiche au recto, fond au dos), dans un
  `RepaintBoundary`. Retournement en `Matrix4` avec perspective, trajet en rectangle, coins qui
  s'effacent, écrasement en échelle. Pas de flou, pas de `BackdropFilter`, pas de `saveLayer` hormis le
  fondu final de cet élément.
- **La fiche n'est pas peinte avant l'atterrissage** (opacité nulle : Flutter saute sa peinture) mais
  elle est construite dès le clic, pour que son chargement tourne pendant le vol. Elle garde toujours la
  même place dans l'arbre : la reparenter en route perdrait son état.
- **Mêmes images, même cache.** Le survol préchauffe (`PosterFlight.warm`, via
  `AppNetworkImage.precache`) l'affiche et le fond à la largeur exacte où la carte et la fiche les
  décodent. L'envol ne télécharge rien qu'il n'ait déjà.
- **Le fond reste à l'écran pendant le chargement** de la fiche : la carte le connaît avant le réseau.
- **Les textes de la fiche tombent à l'atterrissage** (`FlightDrop`, ressort `easeOutBack`), sans effet
  hors envol.
- **Au survol** : l'image grossit de 5 % en 700 ms (une échelle de l'image déjà décodée) et les lignes
  du cartouche montent l'une après l'autre (`HoverLine`, 75 ms d'écart, une part de durée plutôt qu'une
  minuterie).
- **Dégradations.** Mode léger : pas de retournement, d'ombre ni d'écrasement, l'affiche s'étend en
  fondu sur le fond (520 ms au total), retour sans fondu. Mouvement réduit demandé, titre sans fond, carte
  hors écran : route ordinaire.

## Conséquences

- Le trajet dure 1,37 s en mode complet, hors de la plage de l'ADR-0086 et d'`AppMotion`. Il reste le
  seul : le survol, lui, respecte la plage hors le zoom lent de l'image (700 ms, comme `AppMotion.ambient`).
- Tant que la route est en transition, l'ancienne page est encore dessinée dessous (0,6 de voile).
  Passé l'atterrissage, Flutter la masque.
- L'ombre portée du retournement est le seul flou du trajet ; le mode léger la retire.
- Seul le catalogue « Demander » lance l'envol. Les autres entrées vers une fiche de demande (listes,
  suggestions) gardent leur route ordinaire.

## À vérifier

- Mesurer les images perdues pendant l'envol sur une Apple TV HD et un PC modeste ; si le retournement
  coûte trop, `FrameBudgetWatch` bascule déjà en mode léger.
- Les décalages fins de MediaHub (zoom Ken Burns du fond de la fiche, fondu flou de la copie) ne sont pas
  repris.
