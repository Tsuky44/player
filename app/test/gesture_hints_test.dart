import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/hooks/use_gesture_hints.dart';

// `testWidgets` pour son horloge : `pump` fait avancer les minuteries, et un
// test qui en laisse une en attente échoue de lui-même.
void main() {
  testWidgets('une rafale de doubles taps dans le même sens s’additionne',
      (tester) async {
    final hints = GestureHints();
    hints
      ..showSeek(10)
      ..showSeek(10)
      ..showSeek(10);
    expect(hints.seekSeconds, 30);
    expect(hints.seekForward, isTrue);
    expect(hints.seekPulse, 3);

    // Repartir dans l'autre sens recommence le compte.
    hints.showSeek(-10);
    expect(hints.seekSeconds, 10);
    expect(hints.seekForward, isFalse);
    hints.dispose();
  });

  testWidgets('l’indication s’efface, puis quitte l’arbre', (tester) async {
    final hints = GestureHints();
    var notified = 0;
    hints.addListener(() => notified++);

    hints.showZoom(BoxFit.cover);
    expect(hints.zoomMounted, isTrue);
    expect(hints.zoomVisible, isTrue);

    await tester.pump(const Duration(milliseconds: 900));
    expect(hints.zoomVisible, isFalse);
    expect(hints.zoomMounted, isTrue, reason: 'le fondu est en cours');

    await tester.pump(const Duration(milliseconds: 300));
    expect(hints.zoomMounted, isFalse);
    expect(notified, 3);
    hints.dispose();
  });

  testWidgets('une rafale interrompue après le fondu repart de zéro',
      (tester) async {
    final hints = GestureHints()..showSeek(10);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(hints.seekMounted, isFalse);

    hints.showSeek(10);
    expect(hints.seekSeconds, 10);
    hints.dispose();
  });

  testWidgets('rien ne reste en attente après la destruction', (tester) async {
    GestureHints()
      ..showSeek(10)
      ..showZoom(BoxFit.contain)
      ..dispose();
  });
}
