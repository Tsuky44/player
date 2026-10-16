import 'package:flutter/widgets.dart';

import 'video_display_mode.dart';

/// Which way a pinch went: fingers spread apart, or squeezed together.
enum PinchZoom {
  spread,
  squeeze;

  /// Le mode d'affichage où ce pincement mène depuis [from] : un cran de zoom,
  /// dans l'ordre de [VideoDisplayMode].
  VideoDisplayMode apply(VideoDisplayMode from) =>
      this == spread ? from.zoomedIn : from.zoomedOut;
}

/// Reads a pinch as one step between the player's display modes.
///
/// There is nothing to zoom *to* in a video surface — no detail waiting at 3x,
/// no pan afterwards. A pinch here means one step along [VideoDisplayMode]:
/// one more band of black gone, or one given back. So the gesture is not
/// tracked continuously; it is read for its direction and resolved once, which
/// is what makes it feel instant instead of asking the user to spread their
/// fingers all the way for a change that has no in-between.
abstract final class PinchZoomFit {
  /// Deliberately short of a full spread, for the reason above: the smallest
  /// movement that says which of the two the user meant.
  static const double spreadThreshold = 1.12;
  static const double squeezeThreshold = 0.88;

  /// The direction this pinch is asking for, or null while it says nothing yet.
  ///
  /// [pointerCount] matters because a scale recognizer also reports one-finger
  /// drags, with [scale] pinned at 1.0. Those belong to the tap zones over the
  /// video, not here.
  static PinchZoom? resolve({required double scale, required int pointerCount}) {
    if (pointerCount < 2) return null;
    if (scale >= spreadThreshold) return PinchZoom.spread;
    if (scale <= squeezeThreshold) return PinchZoom.squeeze;
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

  /// One step per pinch. Without it, fingers drifting back across the
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

  /// The direction the pinch has just decided on, once per gesture; null
  /// otherwise.
  PinchZoom? move(PointerMoveEvent event) {
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
