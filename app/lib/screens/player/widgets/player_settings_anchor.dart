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

  /// Prefer opening above the button — every anchor sits in the bottom control
  /// row, so above is where the room is.
  ///
  /// Requiring the popup's *full* height to fit above would flip it downward on
  /// a short window and push it off-screen, since below the button there is
  /// only the control row. So the side is chosen by whichever has more room,
  /// and [maxHeight] reports what actually fits there: the caller constrains
  /// the popup to it and the popup's own list scrolls the overflow.
  static ({double? bottom, double? top, double maxHeight}) verticalPlacement({
    required Rect buttonRect,
    required Size screenSize,
    required double popupMaxHeight,
    double gap = gapFromButton,
    double minMargin = minViewportMargin,
  }) {
    final spaceAbove = buttonRect.top - gap - minMargin;
    final spaceBelow =
        screenSize.height - buttonRect.bottom - gap - minMargin;

    if (spaceAbove >= spaceBelow) {
      return (
        bottom: screenSize.height - buttonRect.top + gap,
        top: null,
        maxHeight: spaceAbove.clamp(0.0, popupMaxHeight),
      );
    }
    return (
      bottom: null,
      top: buttonRect.bottom + gap,
      maxHeight: spaceBelow.clamp(0.0, popupMaxHeight),
    );
  }
}
