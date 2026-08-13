import 'package:flutter/material.dart';

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

  /// Poster grid columns — shared by every catalog screen (films, séries,
  /// bibliothèque, demandes) so the poster size never changes between them.
  static int posterGridCount(double width) {
    if (width >= 1400) return 7;
    if (width >= 1100) return 6;
    if (width >= 800) return 5;
    if (width >= 550) return 4;
    return 2;
  }

  static int requestGridCount(double width) => posterGridCount(width);

  /// Cell ratio for poster grids: 2:3 poster + title + subtitle line.
  static const double posterGridAspectRatio = 0.56;
  static const double posterGridMainSpacing = 24;
  static const double posterGridCrossSpacing = 14;

  static double mediaRowCardWidth(BuildContext context) =>
      isCompact(context) ? 118.0 : 150.0;

  static double minTouchTarget(BuildContext context) =>
      isCompact(context) ? 48.0 : 44.0;
}
