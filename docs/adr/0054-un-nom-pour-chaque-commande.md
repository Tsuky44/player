# ADR-0054 — Un nom pour chaque commande, vérifié par un test

- **Statut :** accepté, partiel. Sept écrans ou composants sont mesurés ; **aucun lecteur d'écran
  réel (TalkBack, VoiceOver) n'a été lancé sur l'app.**
- **Date :** 2026-10-08
- **Portée :** `app/test/accessibility_labels_test.dart`,
  `app/lib/screens/player/widgets/onyx/onyx_progress_bar.dart`,
  `app/lib/screens/player/widgets/onyx/onyx_chrome_buttons.dart`,
  `app/lib/widgets/global/app_slider.dart`, `app/lib/widgets/global/overlay_back_button.dart`,
  `app/lib/widgets/global/continue_watching_card.dart`.

## Contexte

Un lecteur d'écran ne lit pas une icône : il lit le nom qu'on lui a donné, ou « bouton » tout
court. L'app dessine presque toutes ses commandes elle-même (le Chrome Onyx, les cartes, les
boutons de verre), et rien ne disait lesquelles avaient un nom.

Mesuré avec la règle `labeledTapTargetGuideline` de Flutter, sur les écrans que tout le monde
traverse, quatre commandes étaient muettes :

- la barre de lecture, annoncée comme une zone à toucher, sans position ni durée ;
- le curseur de volume, qui annonçait « 70 % » sans dire de quoi ;
- le bouton Retour des fiches ;
- l'affiche d'une carte « À reprendre ».

## Décision

1. **Les écrans courants passent la règle de Flutter dans un test** : le chrome du lecteur (large
   et téléphone), l'écran de connexion, la fiche d'un film (téléphone et écran large), la carte
   « À reprendre », l'affiche de la médiathèque. Un écran qui gagne une commande sans nom fait
   échouer le test.
2. **La barre de lecture est un curseur** pour un lecteur d'écran : « Position de lecture, 42:00
   sur 2:00:00 », et dix secondes dans chaque sens.
3. **Un curseur porte un nom** (`AppSlider.semanticLabel`), en plus de sa valeur.
4. **Un nom d'action, pas d'objet** : « Reprendre Dune », pas « Affiche ».

## Alternatives écartées

- **Un test qui scanne le code** à la recherche d'un `GestureDetector` sans `Semantics`. Un nom
  peut venir d'un texte enfant, d'une infobulle ou d'un parent : seul l'arbre monté le sait.
- **Tout mesurer d'un coup.** Chaque écran demande ses doublures de serveur ; ceux qui restent
  s'ajoutent un par un au même test.

## Conséquences

- **Ne sont pas mesurés** : l'accueil, la fiche d'une série, les réglages, les demandes, les
  téléchargements, les menus du lecteur, la barre d'onglets du téléphone (elle déborde de 4 px
  avec la police des tests) et toute l'interface télévision.
- **Ne sont pas traités** : les contrastes, la taille du texte réglée dans le système, et l'ordre
  de lecture. Les animations réduites passent déjà par `AppMotion`, là où il est utilisé.
- `onyx_controls_layer.dart` a perdu ses boutons au profit d'`onyx_chrome_buttons.dart` : il était
  à son plafond de lignes (ADR-0052) quand il a fallu y nommer le volume.
