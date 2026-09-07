import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/avoid_cutouts.dart';

/// A camera bubble on the left edge, a third of the way down.
const Rect bubble = Rect.fromLTWH(0, 60, 40, 40);

const Key upper = Key('upper');
const Key middle = Key('middle');
const Key lower = Key('lower');

/// Three stacked rows of 60, the middle one level with [bubble].
Future<void> pumpRows(WidgetTester tester, {List<Rect> cutouts = const []}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: Column(
            children: [
              for (final key in [upper, middle, lower])
                AvoidCutouts(
                  cutouts: cutouts,
                  child: SizedBox(key: key, height: 60, width: 400),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  // The inset is measured on the way to the screen, so the corrected layout is
  // the frame after the first.
  await tester.pump();
}

void main() {
  group('AvoidCutouts', () {
    testWidgets('moves only the row the cutout lands on', (tester) async {
      await pumpRows(tester, cutouts: const [bubble]);

      // The middle row spans 60..120 and the bubble 60..100: it moves, and it
      // moves by exactly what it takes to clear it.
      expect(tester.getTopLeft(find.byKey(middle)).dx, 40);
      // The others are nowhere near it and stay where they were. This is the
      // whole point: the interface does not step aside as one block.
      expect(tester.getTopLeft(find.byKey(upper)).dx, 0);
      expect(tester.getTopLeft(find.byKey(lower)).dx, 0);
    });

    testWidgets('leaves everything alone when there is no cutout',
        (tester) async {
      await pumpRows(tester);

      for (final key in [upper, middle, lower]) {
        expect(tester.getTopLeft(find.byKey(key)).dx, 0);
      }
    });

    testWidgets('a cutout on the right edge moves the row from that side',
        (tester) async {
      await pumpRows(
        tester,
        cutouts: const [Rect.fromLTWH(360, 60, 40, 40)],
      );

      final row = tester.getRect(find.byKey(middle));
      expect(row.left, 0);
      expect(row.right, 360);
    });

    testWidgets('never moves a row vertically', (tester) async {
      // Sideways or not at all. Moving a row down changes its height, which
      // moves the rows around it — and in a bar pinned to the bottom of the
      // screen, that moves this row too; the next measurement then asks for a
      // different inset and the chrome jitters frame after frame. A bubble
      // that starts above a row is exactly the case that used to trigger it.
      await pumpRows(
        tester,
        cutouts: const [
          Rect.fromLTWH(150, 0, 100, 24),
          Rect.fromLTWH(0, 40, 40, 60),
        ],
      );

      expect(tester.getTopLeft(find.byKey(upper)).dy, 0);
      expect(tester.getTopLeft(find.byKey(middle)).dy, 60);
      expect(tester.getTopLeft(find.byKey(lower)).dy, 120);
    });

    testWidgets('a cutout that merely starts higher up is not from above',
        (tester) async {
      // The bubble spans 40..100 and the middle row 60..120: it reaches into
      // the row from the left, not from the top, and the answer is a sideways
      // move of exactly its width.
      await pumpRows(
        tester,
        cutouts: const [Rect.fromLTWH(0, 40, 40, 60)],
      );

      expect(tester.getTopLeft(find.byKey(middle)).dx, 40);
      expect(tester.getTopLeft(find.byKey(upper)).dx, 40);
    });

    testWidgets('a cutout wider than the row is left alone', (tester) async {
      // Nowhere to move it to: shifting would only make it worse, and an
      // inset bigger than the row would leave nothing to lay out.
      await pumpRows(
        tester,
        cutouts: const [Rect.fromLTWH(0, 60, 400, 40)],
      );

      expect(tester.getTopLeft(find.byKey(middle)).dx, 0);
      expect(tester.getSize(find.byKey(middle)).width, 400);
    });
  });
}
