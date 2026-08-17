import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/theme/app_motion.dart';
import 'package:onyx/widgets/global/glass_chrome.dart';

/// `AppMotion` carries a contract that is invisible on screen: opacity survives
/// reduced motion, geometry does not (`PROJECT_DESIGN.md` §10). These tests pin
/// it, because the only other way to check it is to toggle a system setting.
void main() {
  /// Builds [child] under a MediaQuery with `disableAnimations` forced, and
  /// hands its BuildContext back.
  Future<BuildContext> pumpWithReducedMotion(
    WidgetTester tester, {
    required bool reduced,
  }) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  group('durations stay inside the 180–280 ms contract', () {
    test('every exposed duration is in range', () {
      for (final d in [AppMotion.micro, AppMotion.standard, AppMotion.emphasis]) {
        expect(d.inMilliseconds, greaterThanOrEqualTo(180));
        expect(d.inMilliseconds, lessThanOrEqualTo(280));
      }
    });
  });

  testWidgets('fade keeps its duration under reduced motion', (tester) async {
    var context = await pumpWithReducedMotion(tester, reduced: false);
    expect(AppMotion.fade(context), AppMotion.standard);

    context = await pumpWithReducedMotion(tester, reduced: true);
    expect(AppMotion.fade(context), AppMotion.standard);
    expect(AppMotion.fade(context, AppMotion.emphasis), AppMotion.emphasis);
  });

  testWidgets('move collapses to zero under reduced motion', (tester) async {
    var context = await pumpWithReducedMotion(tester, reduced: false);
    expect(AppMotion.move(context), AppMotion.standard);
    expect(AppMotion.move(context, AppMotion.micro), AppMotion.micro);
    expect(AppMotion.reduced(context), isFalse);

    context = await pumpWithReducedMotion(tester, reduced: true);
    expect(AppMotion.move(context), Duration.zero);
    expect(AppMotion.move(context, AppMotion.micro), Duration.zero);
    expect(AppMotion.reduced(context), isTrue);
  });

  group('GlassNavTab consumes the tokens', () {
    Future<AnimatedContainer> pumpTab(
      WidgetTester tester, {
      required bool reduced,
    }) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: MaterialApp(
            home: Scaffold(
              body: GlassNavTab(
                label: 'Films',
                selected: true,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      return tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    }

    testWidgets('animates over micro normally', (tester) async {
      final tab = await pumpTab(tester, reduced: false);
      expect(tab.duration, AppMotion.micro);
      expect(tab.curve, AppMotion.curve);
    });

    testWidgets('does not travel under reduced motion', (tester) async {
      final tab = await pumpTab(tester, reduced: true);
      expect(tab.duration, Duration.zero);
    });
  });
}
