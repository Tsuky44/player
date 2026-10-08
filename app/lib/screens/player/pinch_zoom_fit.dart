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

/// Les doigts posés sur l'image, et la décision d'un pincement en cours.
///
/// The pinch is read from raw pointers rather than from a scale recognizer,
/// and that is the whole reason it answers every time. A recognizer has to
/// win the gesture arena, and over the video it was up against the tap and
/// double-tap of the three seek zones underneath it: a pinch that spread
/// slowly, or whose fingers landed a moment apart, was awarded to a tap
/// before the scale recognizer had seen enough movement to claim it — the
/// "sometimes nothing happens" of it. A [Listener] takes part in no arena at
/// all, so it sees the fingers whatever the taps do, and the taps keep
/// working.
class PinchTracker {
  /// The fingers on the picture right now, and how far apart the first two
  /// were when the second landed.
  final Map<int, Offset> _pointers = <int, Offset>{};
  double? _startSpan;

  /// One fit decision per pinch. Without it, fingers drifting back across the
  /// threshold mid-gesture would keep flipping the picture.
  bool _resolved = false;

  /// How far apart the first two fingers are, or null with fewer than two.
  double? _span() {
    if (_pointers.length < 2) return null;
    final fingers = _pointers.values.toList();
    return (fingers[1] - fingers[0]).distance;
  }

  void down(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    // The span is re-baselined on every finger that lands, so a second finger
    // arriving late starts the pinch from where it actually started.
    _startSpan = _span();
  }

  /// The fit the pinch has just decided on, once per gesture; null otherwise.
  BoxFit? move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return null;
    _pointers[event.pointer] = event.position;
    if (_resolved) return null;
    final start = _startSpan;
    final span = _span();
    if (start == null || span == null || start <= 0) return null;
    final next = PinchZoomFit.resolve(
      scale: span / start,
      pointerCount: _pointers.length,
    );
    if (next == null) return null;
    _resolved = true;
    return next;
  }

  void end(PointerEvent event) {
    _pointers.remove(event.pointer);
    _startSpan = _span();
    // Only once the hand is off the glass: lifting one finger of a pinch that
    // has already answered and spreading again is the same gesture, not a new
    // one, and re-arming there would flip the picture back mid-movement.
    if (_pointers.isEmpty) _resolved = false;
  }
}
