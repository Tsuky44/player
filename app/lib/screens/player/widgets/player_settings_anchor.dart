import 'dart:ui';

/// Computes on-screen placement for player settings popups anchored to a button.
class PlayerSettingsAnchor {
  static const double minViewportMargin = 16;
  static const double gapFromButton = 12;

  static double sheetWidth({required bool hasChaptersTab}) =>
      hasChaptersTab ? 400 : 380;

  static double sheetMaxHeight({required bool hasChaptersTab}) =>
      hasChaptersTab ? 520 : 480;

  static double menuWidth({required bool hasChaptersTab}) =>
      hasChaptersTab ? 400 : 380;

  static double menuMaxHeight({required bool hasChaptersTab}) =>
      hasChaptersTab ? 520 : 480;

  static const double subtitlesSheetWidth = 320;
  static const double subtitlesSheetMaxHeight = 400;

  /// Keeps the popup readable: anchored to the button, shifted when near edges.
  static double horizontalLeft({
    required Rect buttonRect,
    required Size screenSize,
    required double popupWidth,
    double minMargin = minViewportMargin,
  }) {
    final screenWidth = screenSize.width;
    final anchorCenterX = buttonRect.center.dx;

    late double left;
    if (anchorCenterX > screenWidth * 0.62) {
      left = buttonRect.right - popupWidth;
    } else if (anchorCenterX < screenWidth * 0.38) {
      left = buttonRect.left;
    } else {
      left = anchorCenterX - popupWidth / 2;
    }

    final maxLeft = screenWidth - popupWidth - minMargin;
    if (maxLeft <= minMargin) return minMargin;
    return left.clamp(minMargin, maxLeft);
  }

  /// Prefer opening above the button; fall back below when there is not enough room.
  static ({double? bottom, double? top}) verticalPlacement({
    required Rect buttonRect,
    required Size screenSize,
    required double popupMaxHeight,
    double gap = gapFromButton,
    double minMargin = minViewportMargin,
  }) {
    final spaceAbove = buttonRect.top - gap - minMargin;
    if (spaceAbove >= popupMaxHeight) {
      return (bottom: screenSize.height - buttonRect.top + gap, top: null);
    }
    return (bottom: null, top: buttonRect.bottom + gap);
  }
}
