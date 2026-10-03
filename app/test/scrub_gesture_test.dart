import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/widgets/global/scrub_gesture.dart';

/// La barre suit le doigt, et le lecteur ne cherche qu'une fois.
void main() {
  late List<double> seeks;
  late List<bool> scrubbing;
  late double painted;

  Future<void> pump(WidgetTester tester, {double progress = 0.1}) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 40,
            child: ScrubGesture(
              onSeekFraction: seeks.add,
              onScrubbingChanged: scrubbing.add,
              child: ScrubFractionBuilder(
                progress: progress,
                builder: (context, fraction) {
                  painted = fraction;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    seeks = [];
    scrubbing = [];
    painted = -1;
  });

  testWidgets('au repos, la piste peint la position du lecteur', (
    tester,
  ) async {
    await pump(tester, progress: 0.3);
    expect(painted, 0.3);
  });

  testWidgets('pendant le glissé, la piste suit le doigt et aucun seek ne part',
      (tester) async {
    await pump(tester);
    final box = tester.getRect(find.byType(ScrubGesture));
    final gesture =
        await tester.startGesture(box.centerLeft + const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(painted, closeTo(200 / 400, 0.01));
    expect(seeks, isEmpty);
    expect(scrubbing, [true]);

    await gesture.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, closeTo(0.5, 0.01));
    expect(scrubbing, [true, false]);
  });

  testWidgets('un tap cherche une fois, à l’endroit touché', (tester) async {
    await pump(tester);
    final box = tester.getRect(find.byType(ScrubGesture));
    await tester.tapAt(box.centerLeft + const Offset(300, 0));
    await tester.pump();

    expect(seeks, hasLength(1));
    expect(seeks.single, closeTo(0.75, 0.01));
  });

  testWidgets('après le relâchement, la position du lecteur reprend la main', (
    tester,
  ) async {
    await pump(tester, progress: 0.2);
    final box = tester.getRect(find.byType(ScrubGesture));
    await tester.dragFrom(
      box.centerLeft + const Offset(40, 0),
      const Offset(200, 0),
    );
    await tester.pump();
    await tester.pump();
    expect(painted, 0.2);
  });
}
