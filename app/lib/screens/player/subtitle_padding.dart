import 'package:flutter/widgets.dart';

/// Default subtitle padding when player controls are hidden.
const kSubtitlePaddingBase = EdgeInsets.fromLTRB(16, 0, 16, 24);

/// Distance from the screen bottom to the top of the progress bar, used until
/// the bar has been laid out and can be measured.
const kTimelineTopInset = 118.0;

const kSubtitleGapAboveTimeline = 12.0;

/// Computes subtitle bottom padding so text sits above visible player controls.
class SubtitlePaddingCalculator {
  static EdgeInsets resolve({
    required bool controlsVisible,
    required Size screenSize,
    double? measuredTimelineTopDy,
  }) {
    if (!controlsVisible) return kSubtitlePaddingBase;

    if (measuredTimelineTopDy != null) {
      return fromTimelineTop(measuredTimelineTopDy, screenSize);
    }

    return const EdgeInsets.fromLTRB(
      16,
      0,
      16,
      kTimelineTopInset + kSubtitleGapAboveTimeline,
    );
  }

  /// Builds padding from the timeline/progress bar top edge (screen coordinates).
  static EdgeInsets fromTimelineTop(double timelineTopDy, Size screenSize) {
    final bottomInset = (screenSize.height - timelineTopDy)
        .clamp(kSubtitlePaddingBase.bottom, screenSize.height * 0.45);
    return EdgeInsets.fromLTRB(
      16,
      0,
      16,
      bottomInset + kSubtitleGapAboveTimeline,
    );
  }
}
