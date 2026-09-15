import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/main.dart' show AppScrollBehavior;

void main() {
  final vertical = ScrollController();
  final horizontal = ScrollController();

  Widget page() {
    return MaterialApp(
      scrollBehavior: AppScrollBehavior(),
      home: Scaffold(
        body: ListView(
          controller: vertical,
          children: [
            SizedBox(
              height: 200,
              child: ListView(
                controller: horizontal,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(width: 150, child: Text('Affiche $i')),
                ],
              ),
            ),
            for (var i = 0; i < 100; i++)
              SizedBox(height: 120, child: Text('Ligne $i')),
          ],
        ),
      ),
    );
  }

  Future<TestGesture> middleClick(WidgetTester tester, Offset at) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await gesture.addPointer(location: at);
    await gesture.down(at);
    await tester.pump();
    return gesture;
  }

  Future<void> runFor(WidgetTester tester, Duration duration) async {
    const frame = Duration(milliseconds: 16);
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += frame) {
      await tester.pump(frame);
    }
  }

  testWidgets('click, release, move away: the page follows the mouse',
      (tester) async {
    await tester.pumpWidget(page());
    const anchor = Offset(400, 400);

    final gesture = await middleClick(tester, anchor);
    await gesture.up();
    await gesture.moveTo(anchor + const Offset(0, 150));
    await runFor(tester, const Duration(milliseconds: 500));

    expect(vertical.offset, greaterThan(100));

    // A click stops it, and is not passed on to what lies below.
    await gesture.down(anchor + const Offset(0, 150));
    await gesture.up();
    await tester.pump();
    final stoppedAt = vertical.offset;
    await runFor(tester, const Duration(milliseconds: 300));
    expect(vertical.offset, stoppedAt);
  });

  testWidgets('inside the mouse dead zone, nothing moves', (tester) async {
    await tester.pumpWidget(page());
    const anchor = Offset(400, 400);

    final gesture = await middleClick(tester, anchor);
    await gesture.up();
    await gesture.moveTo(anchor + const Offset(5, 5));
    await runFor(tester, const Duration(milliseconds: 300));

    expect(vertical.offset, 0);
    await gesture.down(anchor);
    await gesture.up();
  });

  testWidgets('held and dragged: stops on release', (tester) async {
    await tester.pumpWidget(page());
    const anchor = Offset(400, 400);

    final gesture = await middleClick(tester, anchor);
    await gesture.moveTo(anchor + const Offset(0, 200));
    await runFor(tester, const Duration(milliseconds: 300));
    expect(vertical.offset, greaterThan(0));

    await gesture.up();
    await tester.pump();
    final stoppedAt = vertical.offset;
    await runFor(tester, const Duration(milliseconds: 300));
    expect(vertical.offset, stoppedAt);
  });

  testWidgets('over a row of posters, each axis goes to its own list',
      (tester) async {
    await tester.pumpWidget(page());
    vertical.jumpTo(0);
    horizontal.jumpTo(0);
    await tester.pump();
    const anchor = Offset(400, 100); // inside the horizontal row

    final gesture = await middleClick(tester, anchor);
    await gesture.up();
    // Slow vertically, so the row stays on screen long enough to be read.
    await gesture.moveTo(anchor + const Offset(150, 40));
    await runFor(tester, const Duration(milliseconds: 400));

    expect(horizontal.offset, greaterThan(50));
    expect(vertical.offset, greaterThan(10));
    await gesture.down(anchor);
    await gesture.up();
  });
}
