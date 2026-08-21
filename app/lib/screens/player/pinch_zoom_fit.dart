import 'package:flutter/widgets.dart';

/// Reads a pinch as a choice between the player's two display fits.
///
/// There is nothing to zoom *to* in a video surface — no detail waiting at 3x,
/// no pan afterwards. A pinch here means one of exactly two things: fill the
/// screen and crop the edges, or give the picture back its own proportions.
/// So the gesture is not tracked continuously; it is read for its direction and
/// resolved once, which is what makes it feel instant instead of asking the
/// user to spread their fingers all the way for a change that has no
/// in-between.
abstract final class PinchZoomFit {
  /// Deliberately short of a full spread, for the reason above: the smallest
  /// movement that says which of the two the user meant.
  static const double coverThreshold = 1.12;
  static const double containThreshold = 0.88;

  /// The fit this pinch is asking for, or null while it says nothing yet.
  ///
  /// [pointerCount] matters because a scale recognizer also reports one-finger
  /// drags, with [scale] pinned at 1.0. Those belong to the tap zones over the
  /// video, not here.
  static BoxFit? resolve({required double scale, required int pointerCount}) {
    if (pointerCount < 2) return null;
    if (scale >= coverThreshold) return BoxFit.cover;
    if (scale <= containThreshold) return BoxFit.contain;
    return null;
  }
}
