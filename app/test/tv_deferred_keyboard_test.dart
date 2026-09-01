import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_deferred_keyboard.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Monte le champ différé entouré de deux boutons, comme dans l'en-tête : les
/// onglets avant, l'avatar du compte après.
Future<FocusNode> pumpBar(WidgetTester tester, {required bool isTv}) async {
  final fieldNode = FocusNode();
  addTearDown(fieldNode.dispose);
  final beforeNode = FocusNode();
  addTearDown(beforeNode.dispose);
  final afterNode = FocusNode();
  addTearDown(afterNode.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: TvScope(
        isTv: isTv,
        child: Scaffold(
          body: Row(
            children: [
              Focus(focusNode: beforeNode, child: const SizedBox(width: 40)),
              Expanded(
                child: TvDeferredKeyboard(
                  fieldFocusNode: fieldNode,
                  builder: (context, focusNode, canRequestFocus) => TextField(
                    focusNode: focusNode,
                    canRequestFocus: canRequestFocus,
                  ),
                ),
              ),
              Focus(focusNode: afterNode, child: const SizedBox(width: 40)),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return fieldNode;
}

void main() {
  testWidgets('sur téléviseur, traverser la barre n’ouvre pas le clavier',
      (tester) async {
    final fieldNode = await pumpBar(tester, isTv: true);

    // Le parcours s'arrête bien sur la barre — elle n'est pas sautée…
    primaryFocus?.nextFocus();
    await tester.pump();
    expect(primaryFocus, isNotNull);

    // …mais le champ lui-même ne prend jamais le focus tant qu'on n'a rien
    // demandé, et c'est ce qui empêche Android d'ouvrir son clavier plein
    // écran par-dessus tout ce qui suit dans l'en-tête.
    for (var i = 0; i < 6; i++) {
      primaryFocus?.nextFocus();
      await tester.pump();
      expect(fieldNode.hasFocus, isFalse);
    }
  });

  testWidgets('OK sur la barre donne le focus au champ', (tester) async {
    final fieldNode = await pumpBar(tester, isTv: true);

    // Atteindre la barre, puis l'activer comme le ferait la touche OK.
    for (var i = 0; i < 6 && !_barHasFocus(tester); i++) {
      primaryFocus?.nextFocus();
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(fieldNode.hasFocus, isTrue);
  });

  testWidgets('le champ ressort du parcours quand le clavier se referme',
      (tester) async {
    final fieldNode = await pumpBar(tester, isTv: true);

    for (var i = 0; i < 6 && !_barHasFocus(tester); i++) {
      primaryFocus?.nextFocus();
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fieldNode.hasFocus, isTrue);

    fieldNode.unfocus();
    await tester.pumpAndSettle();

    // Sans ce retour en arrière, le passage suivant de la télécommande
    // rouvrirait le clavier tout seul.
    expect(fieldNode.hasFocus, isFalse);
    primaryFocus?.nextFocus();
    await tester.pump();
    expect(fieldNode.hasFocus, isFalse);
  });

  testWidgets('hors téléviseur, le champ reste un champ ordinaire',
      (tester) async {
    final fieldNode = await pumpBar(tester, isTv: false);

    fieldNode.requestFocus();
    await tester.pump();

    // Rien de tout cela ne s'applique à une souris ou à un doigt : le champ
    // prend le focus au clic, comme avant.
    expect(fieldNode.hasFocus, isTrue);
  });
}

/// Le nœud du champ-bouton est celui de [TvDeferredKeyboard] : il détient le
/// focus sans que le champ ne l'ait.
bool _barHasFocus(WidgetTester tester) =>
    primaryFocus?.debugLabel == 'tv-deferred-keyboard';
