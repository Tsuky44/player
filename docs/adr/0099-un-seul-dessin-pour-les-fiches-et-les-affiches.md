# ADR-0099 — Une seule fiche et une seule affiche : la disposition de la bibliothèque, l'habillage de Demander

- **Statut :** accepté. Le rendu n'a pas été mesuré sur une Apple TV HD ni sur un PC modeste (voir
  « À vérifier »).
- **Date :** 2026-10-30
- **Portée :** `widgets/global/detail_hero.dart`, `detail_backdrop_header.dart`,
  `detail_summary_section.dart`, `detail_info_table.dart`, `detail_cast_section.dart`, `detail_actions.dart`,
  `season_bubbles.dart`, `poster_card.dart`, `poster_card_details.dart`, `poster_rail.dart`, `media_card.dart`,
  `navigation/detail_flight.dart`, les fiches film, série, saison, demande et lien de partage, et les
  grilles de la bibliothèque. Prolonge l'ADR-0094, dont il lève la dernière conséquence : « seul le
  catalogue Demander lance l'envol ».

## Contexte

Deux fiches coexistaient pour le même objet. Demander reprenait OnyxHub : grand fond, logo, pastilles,
colonne d'informations, bulles de saison, affiches seules, cartouche au survol, envol de l'affiche. Les
films et séries gardaient un en-tête de 540 px avec affiche et synopsis, un bouton plein, des onglets de
saison, des affiches titrées, et une route ordinaire ou une ouverture circulaire.

Un premier essai a tout aligné sur Demander, disposition de l'en-tête comprise. Il a été écarté à l'usage :
la disposition de la bibliothèque reste, seuls l'animation et l'habillage des boutons changent.

## Décision

- **Un seul en-tête** (`DetailHero`) pour toutes les fiches, demandes comprises, à la **disposition de la
  bibliothèque** : 540 px, affiche à gauche, logo, accroche, métadonnées et synopsis à droite ; en téléphone,
  les actions sous l'image. `DetailBackdropHeader` n'est plus qu'un adaptateur du catalogue vers lui.
- **Les boutons sont les pastilles de Demander** (`HeroPill`, boutons ronds). `HeroPill` a un focus lisible
  (arête à l'accent, ADR-0008) : la pastille de lecture est le point d'arrivée de la télécommande.
- **Le corps est commun** (`DetailSummarySection`, `DetailInfoTable`) : crédits et mots-clés, colonne
  d'informations. Le synopsis est dans l'en-tête.
- **Les saisons sont les bulles de Demander partout** (`SeasonBubbleRow`, goutte comprise), avec une seule
  marque : **un sablier orange pour une saison demandée**. Une saison disponible ne porte rien. Une saison à
  demander ne porte rien non plus, son numéro est seulement effacé.
- **Une saison ne se demande qu'en la dépliant.** Le « + » des bulles, le bouton global d'une série
  (« Demander », « Compléter », « Demander plus ») et la sélection de plusieurs saisons disparaissent.
  Toucher la saison ouverte la replie, sur la fiche d'une série comme sur celle d'une demande.
- **Une seule affiche** : `PosterCard` en affiche seule, avec `PosterCardDetails` au survol. Le badge vu et
  la barre de progression restent posés dessus. Le disque de lecture au survol disparaît : toucher une
  affiche ouvre sa fiche, il promettait autre chose.
- **Une seule ouverture** : `pushDetailFlight`, depuis toute carte, vers le fond de l'en-tête.
  L'ouverture circulaire est supprimée. Le zoom vers le lecteur (« Reprendre ») ne change pas.
- **Un toucher attend le fond au plus 300 ms.** Une carte de la bibliothèque ne connaît pas son fond, qui
  est dans la fiche. Le survol le prépare ; un téléphone n'a pas de survol, et l'appui a déjà lancé la
  requête. Au-delà, la route ordinaire vaut mieux qu'un appui qui semble ignoré.
- **La filmographie garde le rôle sous l'affiche** : c'est ce qu'on vient y lire, et un téléphone n'a pas de
  survol pour le montrer.
- **La colonne d'informations ne montre plus de note « IMDb »** : c'était la note TMDB sous un autre nom.

## Conséquences

- Une demande perd son grand fond : son en-tête a une hauteur fixe, donc le cadre d'import et le suivi passent
  dessous.
- Demander plusieurs saisons d'un coup se fait une saison à la fois.
- Sur la fiche d'une série, les bulles pilotent la liste d'épisodes de la page, sans le cadre vitré ni la
  lumière du panneau de Demander : la liste reste un sliver construit à la demande.
- Sur un téléphone, une affiche ne dit plus son titre sous elle : l'affiche le porte, et le lecteur
  d'écran le lit (`PosterCard.showMeta`).
- Les grilles passent au ratio 2:3 ; un même écran montre plus d'affiches qu'avant, sur plus de rangées.

## À vérifier

- Mesurer les images perdues pendant l'envol sur une Apple TV HD et un PC modeste, l'envol étant désormais
  le trajet le plus fréquent de l'app (ADR-0094).
- Regarder le parcours au D-pad d'une fiche jusqu'au bout sur une vraie télévision.
