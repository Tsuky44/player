import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../theme/lite_mode.dart';
import 'poster_grid_zoom.dart';

/// Breakpoints and layout helpers for adaptive phone / tablet / desktop UI.
abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double medium = 900;
  static const double expanded = 1200;
}

abstract final class AppLayout {
  static Size sizeOf(BuildContext context) => MediaQuery.sizeOf(context);

  static bool isCompact(BuildContext context) =>
      sizeOf(context).width < AppBreakpoints.compact;

  static bool isMedium(BuildContext context) {
    final w = sizeOf(context).width;
    return w >= AppBreakpoints.compact && w < AppBreakpoints.medium;
  }

  static bool isWide(BuildContext context) =>
      sizeOf(context).width >= AppBreakpoints.medium;

  /// Horizontal page gutter: 16 phone · 24 tablet · 48 desktop.
  static double pagePadding(BuildContext context) {
    final w = sizeOf(context).width;
    if (w >= AppBreakpoints.medium) return 48;
    if (w >= AppBreakpoints.compact) return 24;
    return 16;
  }

  static EdgeInsets pageInsets(
    BuildContext context, {
    double top = 0,
    double bottom = 0,
  }) {
    final h = pagePadding(context);
    return EdgeInsets.fromLTRB(h, top, h, bottom);
  }

  /// Ideal width of one poster cell. Grids fit as many whole columns of about
  /// this width as the row allows, so a poster keeps the same physical size
  /// everywhere: a wider window simply shows more of them.
  static const double posterTileTarget = 150;

  /// A cell never gets narrower than this — below it the title and the rating
  /// line stop being readable, so the grid drops a column instead.
  static const double posterTileMin = 135;

  /// Poster grid columns for a row of [contentWidth] logical pixels (the width
  /// left *after* the page gutters). Shared by every catalog screen (films,
  /// séries, bibliothèque, demandes) so the poster size never changes between
  /// them.
  static int posterGridCount(double contentWidth, {double? spacing}) {
    final gap = spacing ?? posterGridCrossSpacing;
    var columns = ((contentWidth + gap) / (posterTileTarget + gap)).round();
    // Rounding up must not squeeze the cells below the readable minimum.
    while (columns > 2 &&
        (contentWidth - gap * (columns - 1)) / columns < posterTileMin) {
      columns--;
    }
    return columns < 2 ? 2 : columns;
  }

  static int requestGridCount(double contentWidth, {double? spacing}) =>
      posterGridCount(contentWidth, spacing: spacing);

  /// Cell ratio for poster grids: 2:3 poster + title + subtitle line.
  static const double posterGridAspectRatio = 0.56;

  /// Cell ratio for a grid of bare posters (2:3, no text underneath).
  static const double posterOnlyAspectRatio = 2 / 3;
  static const double posterGridMainSpacing = 24;
  static const double posterGridCrossSpacing = 14;
  static const double posterGridCompactMainSpacing = 16;
  static const double posterGridCompactCrossSpacing = 10;

  /// The one grid delegate every catalog grid uses. [contentWidth] is the row
  /// width inside the page gutters — take it from a `SliverLayoutBuilder` so
  /// side navigation is accounted for, not from the window width.
  ///
  /// [withMeta] faux pour une grille d'affiches seules, sans titre dessous :
  /// la cellule prend le ratio 2:3 de l'affiche.
  ///
  /// [context] est celui du `SliverLayoutBuilder` : la grille suit le zoom
  /// Ctrl + molette de `PosterGridZoomRegion` (`PosterGridZoom`).
  static SliverGridDelegate posterGridDelegate(
    BuildContext context,
    double contentWidth, {
    bool compact = false,
    bool withMeta = true,
  }) {
    final cross =
        compact ? posterGridCompactCrossSpacing : posterGridCrossSpacing;
    final zoom = PosterGridZoomScope.watch(context);
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: zoom.apply(posterGridCount(contentWidth, spacing: cross)),
      crossAxisSpacing: cross,
      // Sans ligne de titre à séparer de la rangée suivante, l'écart vertical
      // reprend l'horizontal : une trame régulière, comme sur OnyxHub.
      mainAxisSpacing: !withMeta
          ? cross
          : compact
              ? posterGridCompactMainSpacing
              : posterGridMainSpacing,
      childAspectRatio:
          withMeta ? posterGridAspectRatio : posterOnlyAspectRatio,
    );
  }

  static double mediaRowCardWidth(BuildContext context) =>
      isCompact(context) ? 118.0 : 150.0;

  /// La marge construite hors de l'écran par une liste d'images : une
  /// fenêtre entière de chaque côté, sur l'axe du défilement.
  ///
  /// Les 250 px de Flutter ne couvrent même pas une rangée d'affiches : une
  /// carte ne demandait son image qu'en entrant à l'écran, et l'espace réservé
  /// se voyait le temps du téléchargement et du décodage. Une fenêtre d'avance,
  /// c'est l'image déjà décodée quand la carte arrive (ADR-0088).
  ///
  /// Null en mode léger : la valeur de Flutter. Sur une Apple TV HD, des
  /// dizaines d'affiches décodées en plus disputeraient la mémoire au
  /// décodeur vidéo (ADR-0086).
  static ScrollCacheExtent? imageCacheExtent(BuildContext context) =>
      LiteScope.of(context) ? null : const ScrollCacheExtent.viewport(1);

  static double minTouchTarget(BuildContext context) =>
      isCompact(context) ? 48.0 : 44.0;
}
