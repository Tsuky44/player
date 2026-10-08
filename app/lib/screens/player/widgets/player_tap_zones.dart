import 'package:flutter/material.dart';

import '../pinch_zoom_fit.dart';

/// Les trois zones de l'image — recul, milieu, avance — et le pincement qui
/// les enjambe.
///
/// A pinch spans two of the tap zones, so it cannot be handled by them: the
/// fingers have to be counted somewhere above all three. Watching the pointers
/// rather than competing for them is what makes it reliable — see
/// [PinchTracker].
class PlayerTapZones extends StatelessWidget {
  const PlayerTapZones({
    super.key,
    required this.pinch,
    required this.onPinchFit,
    required this.doubleTapTogglesFullscreen,
    required this.onDoubleTapFullscreen,
    required this.onDoubleTapSeek,
    required this.onSideTap,
    required this.onCenterTap,
    required this.onWindowDrag,
  });

  /// Null off a touchscreen: nothing there can produce a second finger, and
  /// tracking would only be bookkeeping.
  final PinchTracker? pinch;
  final ValueChanged<BoxFit> onPinchFit;

  /// A double-click opens and closes full screen instead of seeking.
  final bool doubleTapTogglesFullscreen;
  final VoidCallback onDoubleTapFullscreen;
  final ValueChanged<int> onDoubleTapSeek;
  final ValueChanged<int> onSideTap;
  final VoidCallback onCenterTap;

  /// Null where there is no window to move.
  final VoidCallback? onWindowDrag;

  Widget _zone({
    required int flex,
    required VoidCallback onTap,
    required VoidCallback? onDoubleTap,
  }) {
    final drag = onWindowDrag;
    return Expanded(
      flex: flex,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: onDoubleTap,
        onTap: onTap,
        onPanStart: drag != null ? (_) => drag() : null,
        child: Container(color: Colors.transparent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracker = pinch;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: tracker?.down,
      onPointerMove: tracker == null
          ? null
          : (event) {
              final fit = tracker.move(event);
              if (fit != null) onPinchFit(fit);
            },
      onPointerUp: tracker?.end,
      onPointerCancel: tracker?.end,
      child: Row(
        children: [
          _zone(
            flex: 3,
            onDoubleTap: doubleTapTogglesFullscreen
                ? onDoubleTapFullscreen
                : () => onDoubleTapSeek(-10),
            onTap: () => onSideTap(-10),
          ),
          // The middle never had a double-tap: there is no ±10 s zone at the
          // centre of the picture. Full screen, though, is taken from
          // anywhere.
          _zone(
            flex: 4,
            onTap: onCenterTap,
            onDoubleTap:
                doubleTapTogglesFullscreen ? onDoubleTapFullscreen : null,
          ),
          _zone(
            flex: 3,
            onDoubleTap: doubleTapTogglesFullscreen
                ? onDoubleTapFullscreen
                : () => onDoubleTapSeek(10),
            onTap: () => onSideTap(10),
          ),
        ],
      ),
    );
  }
}
