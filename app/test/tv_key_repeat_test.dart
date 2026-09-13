import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_key_repeat.dart';
import 'package:onyx/tv/tv_mode.dart';

void main() {
  setUpAll(TvKeyRepeat.install);
  setUp(() {
    TvMode.enabled.value = true;
    TvKeyRepeat.debugReset();
  });
  tearDown(() => TvMode.enabled.value = false);

  Future<List<FocusNode>> pumpRow(WidgetTester tester, int count) async {
    final nodes = [
      for (var i = 0; i < count; i++) FocusNode(debugLabel: 'card$i'),
    ];
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(MaterialApp(
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        DirectionalFocusIntent: TvDirectionalFocusAction(),
      },
      home: Row(
        children: [
          for (final node in nodes)
            Focus(focusNode: node, child: const SizedBox(width: 40, height: 40)),
        ],
      ),
    ));
    nodes.first.requestFocus();
    await tester.pump();
    return nodes;
  }

  int focusedIndex(List<FocusNode> nodes) =>
      nodes.indexWhere((node) => node.hasFocus);

  testWidgets('une flèche maintenue ne dépasse pas le débit régulé',
      (tester) async {
    final nodes = await pumpRow(tester, 10);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // Une rafale de répétitions arrivées dans le même instant : une seule
    // passe, les autres attendent l'intervalle.
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(focusedIndex(nodes), lessThanOrEqualTo(3));
  });

  testWidgets('des appuis distincts ne sont jamais retenus', (tester) async {
    final nodes = await pumpRow(tester, 10);

    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();

    expect(focusedIndex(nodes), 5);
  });
}
