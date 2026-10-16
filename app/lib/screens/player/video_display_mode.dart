import 'package:flutter/material.dart';

import '../../l10n/tr.dart';

/// Les modes d'affichage du lecteur, du moins zoomé au plus zoomé.
///
/// Chacun n'est qu'un zoom qui garde le rapport de l'image : rien ne s'étire
/// jamais, ce qui sort de l'écran est rogné. Ils ne diffèrent que par les
/// bandes noires qu'ils acceptent de laisser. Voir ADR-0063.
///
/// Un mode ne dit que l'intention. Sur une image qui a déjà la forme de
/// l'écran, les trois se dessinent pareil, et un épisode 16:9 sur un écran plus
/// large n'a rien en haut ni en bas à supprimer : « Remplir la hauteur » y est
/// « Original ».
enum VideoDisplayMode {
  /// L'image entière, avec des bandes là où elle n'a pas la forme de l'écran.
  original(BoxFit.contain),

  /// Les bandes du haut et du bas disparaissent, celles des côtés restent : un
  /// film plus large que l'écran prend toute la hauteur et ses côtés sortent.
  fillHeight(BoxFit.fitHeight),

  /// Plus aucune bande : l'image couvre l'écran, ce qui dépasse est rogné.
  fill(BoxFit.cover);

  const VideoDisplayMode(this.fit);

  /// Le cadrage que les moteurs savent appliquer.
  final BoxFit fit;

  /// En dessous de ce plus petit côté (pixels logiques), un écran tenu en
  /// main est un téléphone.
  static const double tabletShortestSide = 600;

  /// Le mode d'un lecteur où l'utilisateur n'a encore rien choisi.
  ///
  /// Sur un téléphone tenu à l'horizontale, l'écran fait 20:9 au mieux et
  /// presque tout film est plus large : des bandes en haut et en bas d'un
  /// écran déjà petit, c'était payer le cadrage là où l'image est la plus
  /// rare. Il remplit donc sa hauteur. Une tablette, en 4:3 ou presque, y
  /// perdrait un quart de chaque côté d'un épisode 16:9 : elle garde, comme un
  /// téléviseur ou un ordinateur, l'image entière.
  static VideoDisplayMode defaultFor({
    required bool handheld,
    required Size screen,
  }) {
    final phone = handheld && screen.shortestSide < tabletShortestSide;
    return phone ? fillHeight : original;
  }

  /// Un cran de zoom de plus, ou le même au bout de la liste.
  VideoDisplayMode get zoomedIn =>
      index < values.length - 1 ? values[index + 1] : this;

  /// Un cran de zoom de moins, ou le même au début de la liste.
  VideoDisplayMode get zoomedOut => index > 0 ? values[index - 1] : this;

  String get label => switch (this) {
        original => tr('Original'),
        fillHeight => tr('Remplir la hauteur'),
        fill => tr('Remplir l\'écran'),
      };

  String get description => switch (this) {
        original => tr('Image entière, bandes noires si besoin'),
        fillHeight => tr('Sans bandes en haut ni en bas, côtés rognés'),
        fill => tr('Sans aucune bande noire, bords rognés'),
      };

  IconData get icon => switch (this) {
        original => Icons.fit_screen_rounded,
        fillHeight => Icons.height_rounded,
        fill => Icons.crop_free_rounded,
      };
}
