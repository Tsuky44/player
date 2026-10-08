import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/pinch_zoom_fit.dart';

void main() {
  pinchTrackerTests();

  BoxFit? pinch(double scale, {int fingers = 2}) =>
      PinchZoomFit.resolve(scale: scale, pointerCount: fingers);

  test('spreading two fingers fills the screen', () {
    expect(pinch(1.4), BoxFit.cover);
  });

  test('pinching two fingers back restores the original framing', () {
    expect(pinch(0.6), BoxFit.contain);
  });

  // The gesture has to answer well before a full spread: there is no zoom
  // level to aim at, only a direction, so waiting for 2x would read as the
  // pinch being ignored.
  test('a small but unambiguous spread is already enough', () {
    expect(pinch(1.15), BoxFit.cover);
    expect(pinch(0.85), BoxFit.contain);
  });

  test('a hand that has barely moved decides nothing', () {
    expect(pinch(1.0), isNull);
    expect(pinch(1.05), isNull);
    expect(pinch(0.95), isNull);
  });

  // A scale recognizer reports one-finger drags too, with scale stuck at 1.0 —
  // but a drag that wanders can still report a scale off 1.0, and it must not
  // reshape the picture. Two fingers on the glass is the whole gesture.
  test('one finger is never a pinch, whatever the scale says', () {
    expect(pinch(1.4, fingers: 1), isNull);
    expect(pinch(0.6, fingers: 1), isNull);
    expect(pinch(1.4, fingers: 0), isNull);
  });
}

// Le suivi des doigts, au-dessus des zones de tap. Voir [PinchTracker].
PointerDownEvent _fingerDown(int pointer, Offset at) =>
    PointerDownEvent(pointer: pointer, position: at);

PointerMoveEvent _fingerMove(int pointer, Offset to) =>
    PointerMoveEvent(pointer: pointer, position: to);

void pinchTrackerTests() {
  group('PinchTracker', () {
    test('deux doigts qui s’écartent décident une fois, pas à chaque geste',
        () {
      final tracker = PinchTracker()
        ..down(_fingerDown(1, const Offset(100, 100)))
        ..down(_fingerDown(2, const Offset(200, 100)));

      expect(tracker.move(_fingerMove(2, const Offset(205, 100))), isNull);
      expect(tracker.move(_fingerMove(2, const Offset(260, 100))), BoxFit.cover);
      // Les doigts qui reviennent en arrière ne rebasculent pas l'image.
      expect(tracker.move(_fingerMove(2, const Offset(150, 100))), isNull);
    });

    test('un nouveau pincement n’est possible qu’une fois la main levée', () {
      final tracker = PinchTracker()
        ..down(_fingerDown(1, const Offset(100, 100)))
        ..down(_fingerDown(2, const Offset(200, 100)));
      expect(tracker.move(_fingerMove(2, const Offset(260, 100))), BoxFit.cover);

      // Un doigt levé puis reposé : c'est le même geste.
      tracker
        ..end(const PointerUpEvent(pointer: 2))
        ..down(_fingerDown(2, const Offset(260, 100)));
      expect(tracker.move(_fingerMove(2, const Offset(120, 100))), isNull);

      tracker
        ..end(const PointerUpEvent(pointer: 1))
        ..end(const PointerUpEvent(pointer: 2))
        ..down(_fingerDown(1, const Offset(100, 100)))
        ..down(_fingerDown(2, const Offset(300, 100)));
      expect(
          tracker.move(_fingerMove(2, const Offset(150, 100))), BoxFit.contain);
    });

    test('un seul doigt ne pince rien', () {
      final tracker = PinchTracker()
        ..down(_fingerDown(1, const Offset(100, 100)));
      expect(tracker.move(_fingerMove(1, const Offset(400, 100))), isNull);
    });
  });
}
