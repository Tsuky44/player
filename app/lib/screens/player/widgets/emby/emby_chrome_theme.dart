import 'package:flutter/material.dart';

/// Locked visual constants for the Emby fixed chrome.
///
/// Nothing here reads from [PlayerLayoutConfig]: this chrome deliberately
/// ignores skin, blur, glass opacity and accent colour. "Same theme as Emby"
/// and "not editable" are the same requirement — a configurable clone is not
/// a clone.
abstract final class EmbyChromeTheme {
  const EmbyChromeTheme._();

  /// Below this width the chrome switches to its compact arrangement.
  ///
  /// The wide arrangement puts the title block and five utility icons on one
  /// row, which needs roughly 700px of content before it starts colliding.
  static const double compactBreakpoint = 800;

  // --- Colour -------------------------------------------------------------

  /// Icons at rest. They go to [iconActive] on hover/focus.
  static const Color icon = Color(0xD9FFFFFF); // white 85%
  static const Color iconActive = Colors.white;
  static const Color iconDisabled = Color(0x59FFFFFF); // white 35%

  static const Color title = Colors.white;
  static const Color meta = Color(0x99FFFFFF); // white 60%
  static const Color time = Color(0xB3FFFFFF); // white 70%

  /// Played portion of the scrubber — white, as in Emby.
  static const Color progressPlayed = Colors.white;
  static const Color progressBuffered = Color(0x4DFFFFFF); // white 30%
  static const Color progressTrack = Color(0x33FFFFFF); // white 20%
  static const Color chapterMark = Color(0x8AFFFFFF); // white 54%

  static const Color tooltipSurface = Color(0xF21C1C1C);

  /// Top and bottom scrims. Flat gradients, no blur anywhere in this chrome.
  static const LinearGradient topScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x99000000), Color(0x00000000)],
  );

  static const LinearGradient bottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xE6000000), Color(0x8A000000), Color(0x00000000)],
    stops: [0.0, 0.45, 1.0],
  );

  // --- Metrics ------------------------------------------------------------

  /// Sizes are split in two fixed sets rather than scaled continuously: at
  /// phone widths a scaled-down icon lands well under the 44px touch target,
  /// which would make the chrome unusable on the very devices it has to serve.
  ///
  /// [scale] trims what is *drawn* without touching what is touched — see
  /// [EmbyChromeMetrics.scaledBy]. It is how an iPhone gets a slightly smaller
  /// chrome than the same widget on Android.
  static EmbyChromeMetrics metricsFor(double width, {double scale = 1}) {
    final base = width < compactBreakpoint
        ? const EmbyChromeMetrics.compact()
        : const EmbyChromeMetrics.wide();
    return scale == 1 ? base : base.scaledBy(scale);
  }
}

/// The two size sets of the Emby chrome, picked by width.
class EmbyChromeMetrics {
  /// Edge padding around the whole chrome.
  final double gutter;

  /// Tappable box around an icon — never below 44 on touch-sized widths.
  final double hitSize;

  /// Drawn icon size inside that box.
  final double iconSize;

  /// Play/pause is the one oversized control in the transport row.
  final double playIconSize;

  final double titleSize;
  final double metaSize;
  final double timeSize;

  /// Scrubber bar thickness at rest and while hovered/dragged.
  final double barThickness;
  final double barThicknessActive;
  final double handleSize;

  /// Gap between two icons in a cluster.
  final double clusterGap;

  final bool isCompact;

  const EmbyChromeMetrics.wide()
      : gutter = 32,
        hitSize = 40,
        iconSize = 22,
        playIconSize = 34,
        titleSize = 28,
        metaSize = 14,
        timeSize = 13,
        barThickness = 4,
        barThicknessActive = 6,
        handleSize = 13,
        clusterGap = 4,
        isCompact = false;

  const EmbyChromeMetrics.compact()
      : gutter = 16,
        hitSize = 44,
        iconSize = 21,
        playIconSize = 32,
        titleSize = 18,
        metaSize = 12,
        timeSize = 12,
        barThickness = 4,
        barThicknessActive = 6,
        handleSize = 13,
        clusterGap = 0,
        isCompact = true;

  const EmbyChromeMetrics._({
    required this.gutter,
    required this.hitSize,
    required this.iconSize,
    required this.playIconSize,
    required this.titleSize,
    required this.metaSize,
    required this.timeSize,
    required this.barThickness,
    required this.barThicknessActive,
    required this.handleSize,
    required this.clusterGap,
    required this.isCompact,
  });

  /// The same chrome, drawn smaller.
  ///
  /// Only what is *seen* shrinks: text, icons, margins. [hitSize] and the
  /// scrubber's own thickness are left alone, because they are not style —
  /// they are the size of a fingertip and of a target that has to be hit while
  /// a film is playing. A chrome that looks 10% smaller and is 10% harder to
  /// press is not the same trade.
  EmbyChromeMetrics scaledBy(double factor) => EmbyChromeMetrics._(
        gutter: gutter * factor,
        hitSize: hitSize,
        iconSize: iconSize * factor,
        playIconSize: playIconSize * factor,
        titleSize: titleSize * factor,
        metaSize: metaSize * factor,
        timeSize: timeSize * factor,
        barThickness: barThickness,
        barThicknessActive: barThicknessActive,
        handleSize: handleSize,
        clusterGap: clusterGap * factor,
        isCompact: isCompact,
      );
}
