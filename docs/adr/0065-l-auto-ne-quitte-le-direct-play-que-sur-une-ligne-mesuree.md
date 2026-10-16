# ADR-0065 — L'Auto ne quitte le Direct Play que sur une ligne mesurée

- **Statut :** accepté. Couvert par des tests du pilote. **Pas encore rejoué au banc
  (`app/tool/auto_probe_main.dart`), ni sur un appareil Android TV.**
- **Date :** 2026-10-16
- **Portée :** `app/lib/screens/player/playback/auto_trust.dart`,
  `app/lib/screens/player/hooks/use_auto_quality.dart`,
  `app/lib/screens/player/hooks/player_controller_auto.dart` (`_autoSound`, `sideMeasure`),
  `app/test/auto_quality_pilot_test.dart`.
- **Prolonge :** [ADR-0056](0056-qualite-automatique.md), dont il corrige les §2 et §4 sans
  toucher aux seuils de la pente.

## Contexte

En Auto, la lecture passait en transcodage sur des lignes qui portaient le fichier. L'ADR-0056
accuse la ligne quand l'avance en mémoire fond (moins de 92 % reçus, moins de quinze secondes
d'avance). Cette pente ne dit la vérité que si le moteur **essaie** de remplir son cache. Or
chaque moteur borne le sien :

- mpv en octets (`demuxer-max-bytes`) : le cache plein tient d'autant moins de secondes que la
  scène est lourde, et une scène plus lourde fait fondre ces secondes sans que la ligne y soit
  pour rien ;
- ExoPlayer entre un plancher et un plafond (`PlaybackProfile.readaheadSecs`, la moitié et le
  tout) et sous une cible en octets : il cesse de charger au plafond et laisse fondre jusqu'au
  plancher, une pente de zéro pendant de longues secondes. Sur un boîtier TV, le plancher d'une
  session HLS est de quinze secondes, le seuil même de l'Auto.

La sonde aggravait l'erreur. Sous mpv, elle prenait `cache-speed` pour la ligne : un cache
plein qui se recharge au fil de la lecture reçoit ce qu'il lit, et la ligne « mesurée » tombait
au débit de la scène, donc sous celui du fichier. Ailleurs, la mesure à côté disculpait bien la
ligne, mais la règle « une fois on laisse passer, la deuxième un cran de moins » faisait
descendre au cycle suivant du cache.

## Décision

1. **Sur une pente, la ligne se mesure à côté de la lecture** (`sideMeasure`), jamais d'après
   ce que le moteur reçoit. Pendant une vraie coupure, le cache est vide et le moteur tire tout
   ce que la ligne porte : là, ce qu'il reçoit reste la mesure.
2. **Une mesure qui disculpe la ligne vaut trois minutes** (`AutoTrust`) : la pente n'est plus
   crue pendant ce temps, à tous les barreaux. Une remontée vaut une telle mesure pour la source
   où elle arrive. Seule une vraie coupure peut alors faire descendre.
3. **Sans mesure, une pente ne quitte jamais le Direct Play.**
4. **Le Direct Play laisse passer deux coupures en trois minutes** sur une ligne qui le porte,
   ou qu'on n'a pas pu mesurer. La troisième descend. Un barreau en laisse passer une, comme
   avant.
5. **Pendant un délai de grâce**, le Direct Play ne se quitte que sur une ligne qui livre moins
   de 80 % du fichier, et non plus moins de 100 % : un moteur qui vient d'ouvrir reçoit encore
   moins que ce que la ligne porte.

Une ligne mesurée sous le fichier fait toujours descendre d'un saut, comme dans l'ADR-0056.

## Alternatives écartées

- **Demander au moteur si son cache est plein** (`demuxer-cache-idle` sous mpv, `isLoading`
  sous ExoPlayer). La réponse serait la plus juste, mais il faudrait l'ajouter aux trois moteurs
  et à leurs greffons, et AetherEngine ne la publie pas. La mesure à côté fonctionne partout.
- **Baisser le seuil de l'avance** (`lowWater`). Le plafond d'un cache en octets dépend du débit
  du fichier : aucun seuil en secondes ne vaut pour un fichier à 5 Mbit/s et un remux 4K à la
  fois.

## Conséquences

- **Une ligne qui se dégrade dans les trois minutes qui suivent une mesure favorable n'est vue
  qu'à la première coupure**, et non plus avant elle. C'est le prix d'une pente qu'on ne croit
  plus quand elle a déjà menti.
- **Sur une ligne qui porte le fichier tout juste**, un fichier à pics laisse voir jusqu'à trois
  coupures avant de quitter le Direct Play, là où il en laissait voir une.
- Chaque pente suspecte coûte une mesure, soit jusqu'à trois secondes de ligne, au plus une fois
  toutes les trois minutes quand la ligne est disculpée.
