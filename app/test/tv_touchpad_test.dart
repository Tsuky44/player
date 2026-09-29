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

  /// Un coup sec sur le trackpad : 2,1 unités en 112 ms, vers la droite ou
  /// vers le bas.
  void flick({bool lift = false, bool down = false}) {
    void touch(TouchpadPhase phase, double travel) => TvTouchpad.handleTouch(
          phase,
          down ? 0 : travel,
          down ? travel : 0,
        );
    touch(TouchpadPhase.began, 0);
    for (var i = 1; i <= 7; i++) {
      clock += const Duration(milliseconds: 16);
      touch(TouchpadPhase.moved, 0.3 * i);
    }
    if (lift) touch(TouchpadPhase.ended, 2.1);
  }

  Future<List<FocusNode>> pumpRow(
    WidgetTester tester, {
    required bool scrollable,
    Axis axis = Axis.horizontal,
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
        Focus(focusNode: node, child: const SizedBox(width: 20, height: 20)),
    ];
    await tester.pumpWidget(MaterialApp(
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        DirectionalFocusIntent: TvDirectionalFocusAction(),
      },
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: axis == Axis.horizontal ? 20 : 800,
          width: axis == Axis.horizontal ? 800 : 20,
          child: scrollable
              ? ListView(scrollDirection: axis, children: cards)
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

    expect(focusedIndex(nodes), 3);
  });

  testWidgets('à la verticale, un glissé descend d’une ligne à la fois',
      (tester) async {
    // À l'essai, un glissé vers le bas sautait des rangées entières de
    // l'accueil et des lignes des réglages.
    final nodes = await pumpRow(tester, scrollable: true, axis: Axis.vertical);

    flick(lift: true, down: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(seconds: 3));

    expect(TvTouchpad.isGliding, isFalse);
    expect(focusedIndex(nodes), 1);
  });

  testWidgets('le lecteur reçoit chaque déplacement du doigt', (tester) async {
    final moves = <double>[];
    void listener(TouchpadMove move) => moves.add(move.dx);
    TvTouchpad.addMoveListener(listener);

    flick();
    expect(TvTouchpad.isSwiping, isTrue);
    TvTouchpad.removeMoveListener(listener);
    TvTouchpad.handleTouch(TouchpadPhase.moved, 2.4, 0);

    expect(moves, hasLength(7));
    expect(moves.fold<double>(0, (a, b) => a + b), closeTo(2.1, 1e-9));
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
    expect(focusedIndex(nodes), 3);
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
