import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus_panes.dart';
import 'package:onyx/tv/tv_key_repeat.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Une liste de catégories à gauche, une page à droite : la forme des
/// paramètres en grand écran.
void main() {
  setUpAll(TvKeyRepeat.install);
  setUp(() {
    TvMode.enabled.value = true;
    TvKeyRepeat.debugReset();
  });
  tearDown(() => TvMode.enabled.value = false);

  FocusNode node(String label) {
    final node = FocusNode(debugLabel: label);
    addTearDown(node.dispose);
    return node;
  }

  Widget target(FocusNode node, {double height = 40}) => Focus(
        focusNode: node,
        child: SizedBox(width: 120, height: height),
      );

  Future<void> pumpPanes(
    WidgetTester tester, {
    required List<Widget> list,
    required List<Widget> page,
  }) {
    return tester.pumpWidget(MaterialApp(
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        DirectionalFocusIntent: TvDirectionalFocusAction(),
      },
      home: TvFocusPanes(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TvFocusPane(child: Column(children: list)),
            const SizedBox(width: 80),
            TvFocusPane(child: Column(children: page)),
          ],
        ),
      ),
    ));
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets(
      'droite entre dans la page même quand aucun réglage n’est à la hauteur '
      'de la catégorie', (tester) async {
    final first = node('cat0');
    final second = node('cat1');
    final setting = node('setting');
    await pumpPanes(
      tester,
      list: [target(first), target(second)],
      // Un titre et un texte occupent le haut de la page : le premier réglage
      // est plus bas que toute la liste.
      page: [const SizedBox(height: 300), target(setting)],
    );
    first.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(setting.hasFocus, isTrue);
  });

  testWidgets('gauche revient à la catégorie quittée, pas à la plus proche',
      (tester) async {
    final first = node('cat0');
    final second = node('cat1');
    final high = node('high');
    final low = node('low');
    await pumpPanes(
      tester,
      list: [target(first), target(second)],
      page: [target(high), const SizedBox(height: 300), target(low)],
    );
    second.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(low.hasFocus, isTrue);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(second.hasFocus, isTrue);

    // Et l'aller-retour ramène au réglage qu'on regardait.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(low.hasFocus, isTrue);
  });

  testWidgets('dans la page, droite reste sur la ligne avant de changer de volet',
      (tester) async {
    final category = node('cat');
    final left = node('left');
    final right = node('right');
    await pumpPanes(
      tester,
      list: [target(category)],
      page: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          target(left),
          target(right),
        ]),
      ],
    );
    left.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(right.hasFocus, isTrue);

    // Le bord droit de la page reste un mur.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(right.hasFocus, isTrue);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(left.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(category.hasFocus, isTrue);
  });

  testWidgets('une page sans rien d’actionnable ne prend pas le focus',
      (tester) async {
    final category = node('cat');
    await pumpPanes(
      tester,
      list: [target(category)],
      page: const [SizedBox(width: 120, height: 300)],
    );
    category.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(category.hasFocus, isTrue);
  });

  testWidgets('droite atteint le bouton posé dans une ligne cliquable',
      (tester) async {
    final category = node('cat');
    final tile = node('tile');
    final action = node('action');
    await pumpPanes(
      tester,
      list: [target(category)],
      page: [
        Focus(
          focusNode: tile,
          child: SizedBox(
            width: 400,
            height: 60,
            child: Align(
              alignment: Alignment.centerRight,
              child: Focus(
                focusNode: action,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ],
    );
    tile.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(action.hasPrimaryFocus, isTrue);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(tile.hasPrimaryFocus, isTrue);
  });

  testWidgets('bas fait défiler la page quand plus rien ne prend le focus',
      (tester) async {
    final only = node('only');
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        DirectionalFocusIntent: TvDirectionalFocusAction(),
      },
      // La forme d'une page de réglages : tout le contenu dans un seul enfant
      // du défilement, donc jamais démonté en sortant de l'écran.
      home: SingleChildScrollView(
        controller: controller,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            target(only),
            // Des statistiques, un journal : à lire, sans rien à actionner.
            const SizedBox(height: 3000),
          ],
        ),
      ),
    ));
    only.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));

    await press(tester, LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });
}
