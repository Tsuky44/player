import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/touchpad_motion.dart';
import 'package:onyx/tv/tv_key_repeat.dart';
import 'package:onyx/tv/tv_mode.dart';
import 'package:onyx/tv/tv_touchpad.dart';

void main() {
  var clock = Duration.zero;

  setUpAll(TvKeyRepeat.install);
  setUp(() {
    // Le banc d'essai vide les observateurs de touches après chaque test.
    TvTouchpad.debugInstallKeyObserver();
    TvMode.enabled.value = true;
    TvKeyRepeat.debugReset();
    TvTouchpad.debugReset();
    clock = Duration.zero;
    TvTouchpad.debugClock = () => clock;
  });
  tearDown(() {
    TvTouchpad.debugReset();
    TvMode.enabled.value = false;
  });

  /// Un coup sec vers la droite sur le trackpad : 1,4 unité en 112 ms.
  void flick({bool lift = false}) {
    TvTouchpad.handleTouch(TouchpadPhase.began, 0, 0);
    for (var i = 1; i <= 7; i++) {
      clock += const Duration(milliseconds: 16);
      TvTouchpad.handleTouch(TouchpadPhase.moved, 0.2 * i, 0);
    }
    if (lift) TvTouchpad.handleTouch(TouchpadPhase.ended, 1.4, 0);
  }

  Future<List<FocusNode>> pumpRow(
    WidgetTester tester, {
    required bool scrollable,
  }) async {
    final nodes = [
      for (var i = 0; i < 30; i++) FocusNode(debugLabel: 'card$i'),
    ];
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    final cards = [
      for (final node in nodes)
        Focus(focusNode: node, child: const SizedBox(width: 20, height: 40)),
    ];
    await tester.pumpWidget(MaterialApp(
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        DirectionalFocusIntent: TvDirectionalFocusAction(),
      },
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 40,
          width: 800,
          child: scrollable
              ? ListView(scrollDirection: Axis.horizontal, children: cards)
              : Row(children: cards),
        ),
      ),
    ));
    nodes.first.requestFocus();
    await tester.pump();
    return nodes;
  }

  int focusedIndex(List<FocusNode> nodes) =>
      nodes.indexWhere((node) => node.hasFocus);

  testWidgets('dans une rangée, un coup sec avance de plusieurs affiches',
      (tester) async {
    final nodes = await pumpRow(tester, scrollable: true);

    flick();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(focusedIndex(nodes), 4);
  });

  testWidgets('sans glissé, une flèche avance d’une seule affiche',
      (tester) async {
    final nodes = await pumpRow(tester, scrollable: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(focusedIndex(nodes), 1);
  });

  testWidgets('hors de ce qui défile, un pas reste un pas', (tester) async {
    // Une barre de boutons : sauter trois commandes d'un geste serait se
    // perdre.
    final nodes = await pumpRow(tester, scrollable: false);

    flick();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(focusedIndex(nodes), 1);
  });

  testWidgets('un geste lâché vif continue sur sa lancée, puis s’arrête',
      (tester) async {
    final nodes = await pumpRow(tester, scrollable: true);

    flick(lift: true);
    expect(TvTouchpad.isGliding, isTrue);
    await tester.pump(const Duration(seconds: 3));

    expect(TvTouchpad.isGliding, isFalse);
    expect(focusedIndex(nodes), 5);
  });

  testWidgets('poser le doigt arrête la lancée', (tester) async {
    final nodes = await pumpRow(tester, scrollable: true);

    flick(lift: true);
    await tester.pump(const Duration(milliseconds: 70));
    expect(focusedIndex(nodes), 1);

    TvTouchpad.handleTouch(TouchpadPhase.began, 0, 0);
    await tester.pump(const Duration(seconds: 3));

    expect(TvTouchpad.isGliding, isFalse);
    expect(focusedIndex(nodes), 1);
  });

  testWidgets('OK pendant la lancée la coupe', (tester) async {
    final nodes = await pumpRow(tester, scrollable: true);

    flick(lift: true);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(seconds: 3));

    expect(focusedIndex(nodes), 1);
  });
}
