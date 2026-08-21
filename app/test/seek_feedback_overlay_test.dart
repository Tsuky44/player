import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/seek_feedback_overlay.dart';

const _viewport = Size(800, 400);

Future<void> pumpOverlay(
  WidgetTester tester, {
  required bool forward,
  int seconds = 10,
  int pulse = 1,
  bool visible = true,
  bool reducedMotion = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = _viewport;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SeekFeedbackOverlay(
            forward: forward,
            seconds: seconds,
            pulse: pulse,
            visible: visible,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The arc is the only [DecoratedBox] the overlay puts on screen.
Finder get _arc => find.descendant(
      of: find.byType(SeekFeedbackOverlay),
      matching: find.byType(DecoratedBox),
    );

double _arcAlpha(WidgetTester tester) {
  final decoration =
      tester.widget<DecoratedBox>(_arc).decoration as BoxDecoration;
  return decoration.color!.a;
}

void main() {
  group('the double-tap seek says what it did', () {
    testWidgets('names the distance the film moved', (tester) async {
      await pumpOverlay(tester, forward: true, seconds: 10);
      expect(find.text('10 s'), findsOneWidget);
    });

    testWidgets('carries a running total through a burst of taps',
        (tester) async {
      // Four taps forward is forty seconds, and the number has to say so while
      // the taps are still coming — that is the whole reason it is a total and
      // not a fixed "10 s".
      await pumpOverlay(tester, forward: true, seconds: 40, pulse: 4);
      expect(find.text('40 s'), findsOneWidget);
      expect(find.text('10 s'), findsNothing);
    });

    testWidgets('sits on the half of the picture that was tapped',
        (tester) async {
      await pumpOverlay(tester, forward: true);
      expect(tester.getCenter(find.text('10 s')).dx,
          greaterThan(_viewport.width / 2));

      await pumpOverlay(tester, forward: false);
      expect(tester.getCenter(find.text('10 s')).dx,
          lessThan(_viewport.width / 2));
    });

    testWidgets('turns its chevrons round when the film goes back',
        (tester) async {
      final chevrons = find.descendant(
        of: find.byType(SeekFeedbackOverlay),
        matching: find.byType(Transform),
      );

      await pumpOverlay(tester, forward: true);
      final forwardTransforms = tester.widgetList(chevrons).length;

      // Backward mirrors each of the three, rather than merely reordering them:
      // an arrow pointing the wrong way is worse than no arrow.
      await pumpOverlay(tester, forward: false);
      expect(tester.widgetList(chevrons).length, forwardTransforms + 3);
    });
  });

  group('the arc', () {
    testWidgets('arrives and leaves within one tap', (tester) async {
      await pumpOverlay(tester, forward: true);

      // Straight after the tap it is still on its way in.
      final onArrival = _arcAlpha(tester);
      await tester.pump(const Duration(milliseconds: 90));
      final atPeak = _arcAlpha(tester);
      expect(atPeak, greaterThan(onArrival));

      // And it is gone by the end of the run, rather than left over the film.
      await tester.pump(const Duration(milliseconds: 400));
      expect(_arcAlpha(tester), lessThan(0.01));
    });

    testWidgets('replays from the start when another tap lands',
        (tester) async {
      await pumpOverlay(tester, forward: true, pulse: 1);
      await tester.pump(const Duration(milliseconds: 250));
      final spent = _arcAlpha(tester);

      await pumpOverlay(tester, forward: true, seconds: 20, pulse: 2);
      await tester.pump(const Duration(milliseconds: 90));
      expect(_arcAlpha(tester), greaterThan(spent),
          reason: 'the second tap has to look different from the first');
    });

    testWidgets('is dropped under reduced motion, and the readout is not',
        (tester) async {
      await pumpOverlay(tester, forward: true, reducedMotion: true);

      expect(_arc, findsNothing);
      expect(find.text('10 s'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(3));
    });
  });

  testWidgets('takes no pointer, so the gesture underneath keeps working',
      (tester) async {
    await pumpOverlay(tester, forward: true);
    expect(
      tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byType(SeekFeedbackOverlay),
              matching: find.byType(IgnorePointer),
            )
            .first,
      ).ignoring,
      isTrue,
    );
  });
}
