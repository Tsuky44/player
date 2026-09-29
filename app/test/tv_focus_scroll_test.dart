import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_focus_scroll.dart';
import 'package:onyx/tv/tv_key_repeat.dart';
import 'package:onyx/tv/tv_mode.dart';

void main() {
  setUp(() {
    TvMode.enabled.value = true;
    TvKeyRepeat.debugReset();
  });
  tearDown(() => TvMode.enabled.value = false);

  /// Une liste verticale montée comme dans l'app : la politique de parcours
  /// passe par [TvFocusScroll.requestFocus].
  Future<(List<FocusNode>, ScrollController)> pumpList(
    WidgetTester tester, {
    required bool tvFocusable,
  }) async {
    final nodes = [for (var i = 0; i < 6; i++) FocusNode(debugLabel: 'row$i')];
    final controller = ScrollController();
    addTearDown(() {
      controller.dispose();
      for (final node in nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(TvScope(
      isTv: true,
      child: MaterialApp(
        actions: <Type, Action<Intent>>{
          ...WidgetsApp.defaultActions,
          DirectionalFocusIntent: TvDirectionalFocusAction(),
        },
        builder: (context, child) => FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(
            requestFocusCallback: TvFocusScroll.requestFocus,
          ),
          child: child!,
        ),
        home: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 300,
            child: ListView(
              controller: controller,
              children: [
                for (final node in nodes)
                  tvFocusable
                      ? TvFocusable(
                          focusNode: node,
                          focusScale: 1,
                          child: const SizedBox(height: 200),
                        )
                      : Focus(
                          focusNode: node,
                          child: const SizedBox(height: 200),
                        ),
              ],
            ),
          ),
        ),
      ),
    ));
    nodes.first.requestFocus();
    await tester.pumpAndSettle();
    return (nodes, controller);
  }

  testWidgets('une flèche fait défiler une seule fois, sans saut',
      (tester) async {
    final (nodes, controller) = await pumpList(tester, tvFocusable: true);
    final start = controller.offset;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // Le parcours de Flutter aurait déjà sauté pour montrer la cible au bord ;
    // seule l'animation de la carte doit déplacer la liste.
    expect(nodes[2].hasFocus, isTrue);
    expect(controller.offset, start);

    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(start));
  });

  testWidgets('un élément ordinaire défile aussi en douceur', (tester) async {
    final (nodes, controller) = await pumpList(tester, tvFocusable: false);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(nodes[2].hasFocus, isTrue);
    final midway = controller.offset;
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(midway));
  });

  testWidgets('hors téléviseur, Flutter garde son défilement', (tester) async {
    TvMode.enabled.value = false;
    final (nodes, controller) = await pumpList(tester, tvFocusable: false);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(nodes[2].hasFocus, isTrue);
    expect(controller.offset, greaterThan(0));
  });
}
