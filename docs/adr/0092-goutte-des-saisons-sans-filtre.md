# ADR-0092 — La goutte des saisons, peinte sans filtre de fusion

- **Statut :** accepté
- **Date :** 2026-10-29
- **Portée :** `screens/requests/widgets/season_liquid.dart`, `season_cascade.dart`, `request_season_list.dart`,
  `request_season_panel.dart`. Corrige l'en-tête de `RequestSeasonList`
  qui écartait la goutte au nom de l'ADR-0086.

## Contexte

MediaHub anime le changement de saison : la bulle quittée se retracte, une goutte file jusqu'à la bulle
choisie, qui se gonfle en rebondissant, puis ses épisodes montent en cascade. La première reprise dans
Onyx avait laissé la goutte de côté : chez MediaHub elle repose sur un filtre SVG de fusion qui redessine
toute la rangée à chaque image, ce qu'une petite TV ne tient pas (ADR-0086). Le résultat était une fiche
fonctionnellement identique mais sans le mouvement qui la caractérise.

## Décision

- **Un seul chemin peint.** La goutte et ses deux gouttelettes de traîne sont des ovales dans un seul
  `Path`, avec un cou qui les retient à la bulle quittée et s'amincit avec la distance. Un
  `CustomPainter` écoute l'horloge et rien d'autre : aucune reconstruction de widget pendant le trajet,
  aucun calque filtré, aucun `saveLayer`. Le chemin est plein et de même sens, donc sans surcharge là où
  les formes se recouvrent.
- **Les ressorts de MediaHub, à l'identique.** `spring` et `smooth` viennent de `lib/spring.ts` ; la
  largeur des bulles suit une `Curve` (`SeasonSpring`) passée à `AnimatedSize`, qui retarde le gonflement
  de la bulle choisie jusqu'à l'arrivée de la goutte (36 % du trajet).
- **La bulle choisie attend la goutte** pour s'éclairer : son verre, son affiche (qui rebondit) et son nom
  sont pilotés par `lit`, posé quand l'horloge passe ce seuil.
- **Une cascade à une horloge.** L'en-tête et chaque épisode montent de 14 px en apparaissant, 35 ms après
  le précédent (`AppMotion.stagger`), les huit premiers seulement, sans échelle ni flou. Un enfant arrivé
  est rendu tel quel, sans calque d'opacité.
- **Rien de tout cela en mode léger ni sous « réduire les animations »** (`AppMotion.reduced`) : pas de
  goutte, pas de cascade, et pas d'`AnimatedSize` du tout (à durée nulle il se mute pendant sa mise en
  page).

## Conséquences

- Le coût d'un changement de saison est une mise en page de la rangée (quelques bulles) et un dessin
  d'un chemin par image pendant 0,9 s. Il n'a pas été mesuré sur une Apple TV HD.
- Les décalages fins de MediaHub vers la droite (le bord de la pilule quittée qui tient) ne sont pas
  repris : `AnimatedSize` ancre la bulle à gauche.
- L'arrivée en douceur sur un épisode visé par un lien n'est pas reprise : l'app n'a pas de lien vers
  un épisode de la fiche d'une demande.
