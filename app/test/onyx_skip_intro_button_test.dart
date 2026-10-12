import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/onyx/onyx_chrome_theme.dart';
import 'package:onyx/screens/player/widgets/onyx/onyx_skip_intro_button.dart';

/// The pill says how long is left before the intro skips itself, the way the
/// next-episode pill does — and says nothing when nothing is counting down.
void main() {
  Future<void> pumpButton(WidgetTester tester, {Duration? autoSkipIn}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: OnyxSkipIntroButton(
            onPressed: () {},
            metrics: const OnyxChromeMetrics.wide(),
            autoSkipIn: autoSkipIn,
          ),
        ),
      ),
    );
  }

  Finder inPill(Type type) => find.descendant(
        of: find.byType(OnyxSkipIntroButton),
        matching: find.byType(type),
      );

  double fillWidth(WidgetTester tester) =>
      tester.getSize(inPill(ColoredBox)).width;

  testWidgets('fills from the left over the countdown', (tester) async {
    await pumpButton(tester, autoSkipIn: const Duration(seconds: 5));
    final full = tester.getSize(inPill(Material)).width;

    expect(fillWidth(tester), 0);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(fillWidth(tester), closeTo(full / 2, 2));
    await tester.pump(const Duration(milliseconds: 2500));
    expect(fillWidth(tester), closeTo(full, 2));
  });

  testWidgets('no fill without a countdown', (tester) async {
    await pumpButton(tester);
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('a frozen countdown empties the pill', (tester) async {
    await pumpButton(tester, autoSkipIn: const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));

    await pumpButton(tester);
    expect(find.byType(FractionallySizedBox), findsNothing);
    // And nothing is left ticking behind it.
    expect(tester.hasRunningAnimations, isFalse);
  });
}
