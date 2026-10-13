import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/pointer_click_zone.dart';

void main() {
  late int clicks;
  late int doubleClicks;
  late int drags;

  Future<void> pumpZone(WidgetTester tester) async {
    clicks = 0;
    doubleClicks = 0;
    drags = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PointerClickZone(
          onClick: () => clicks++,
          onDoubleClick: () => doubleClicks++,
          onDrag: (_) => drags++,
        ),
      ),
    );
  }

  Future<TestGesture> press(WidgetTester tester, Offset at) {
    return tester.startGesture(at, kind: PointerDeviceKind.mouse);
  }

  testWidgets('un clic agit au relâchement, sans attendre un second clic',
      (tester) async {
    await pumpZone(tester);

    final gesture = await press(tester, const Offset(100, 100));
    await gesture.up();

    expect(clicks, 1);
    expect(doubleClicks, 0);
  });

  testWidgets('un clic qui tremble de quelques pixels reste un clic',
      (tester) async {
    await pumpZone(tester);

    final gesture = await press(tester, const Offset(100, 100));
    await gesture.moveBy(const Offset(4, 3));
    await gesture.up();

    expect(clicks, 1);
    expect(drags, 0);
  });

  testWidgets('un vrai glissement déplace la fenêtre et ne clique pas',
      (tester) async {
    await pumpZone(tester);

    final gesture = await press(tester, const Offset(100, 100));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();

    expect(drags, 1);
    expect(clicks, 0);
  });

  testWidgets('le glissement sait quand le bouton a été relâché',
      (tester) async {
    bool Function()? stillHeld;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PointerClickZone(
          onClick: () {},
          onDoubleClick: null,
          onDrag: (held) => stillHeld = held,
        ),
      ),
    );

    final gesture = await press(tester, const Offset(100, 100));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));

    expect(stillHeld!(), isTrue);
    await gesture.up();
    expect(stillHeld!(), isFalse);
  });

  testWidgets('un double-clic rejoue le clic puis signale le double',
      (tester) async {
    await pumpZone(tester);

    await (await press(tester, const Offset(100, 100))).up();
    await tester.pump(const Duration(milliseconds: 120));
    await (await press(tester, const Offset(101, 100))).up();

    // Deux clics : la pause du premier est annulée par le second.
    expect(clicks, 2);
    expect(doubleClicks, 1);
  });

  testWidgets('deux clics espacés ne font pas un double-clic', (tester) async {
    await pumpZone(tester);

    await (await press(tester, const Offset(100, 100))).up();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await (await press(tester, const Offset(100, 100))).up();

    expect(clicks, 2);
    expect(doubleClicks, 0);
  });

  testWidgets('le bouton droit ne clique pas', (tester) async {
    await pumpZone(tester);

    final gesture = await tester.startGesture(
      const Offset(100, 100),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();

    expect(clicks, 0);
  });
}
