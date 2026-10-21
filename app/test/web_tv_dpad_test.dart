import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Un téléviseur LG ouvre l'app web (ADR-0076), dont les raccourcis par défaut
/// sont ceux d'une page : les flèches y font défiler, et le D-pad ne passait
/// plus d'une affiche à l'autre sur l'accueil. [webTvShortcuts] rend aux
/// flèches et à OK leur sens de télécommande.
void main() {
  /// Les raccourcis de `WidgetsApp.defaultShortcuts` sous `kIsWeb`, pour les
  /// touches en cause : un test tourne hors navigateur et aurait sinon les
  /// raccourcis natifs, où le défaut n'existe pas.
  const browserDefaults = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowLeft):
        ScrollIntent(direction: AxisDirection.left),
    SingleActivator(LogicalKeyboardKey.arrowRight):
        ScrollIntent(direction: AxisDirection.right),
    SingleActivator(LogicalKeyboardKey.enter): ButtonActivateIntent(),
  };

  Widget app({required List<Widget> cards}) => TvScope(
        isTv: true,
        child: MaterialApp(
          shortcuts: <ShortcutActivator, Intent>{
            ...browserDefaults,
            ...webTvShortcuts,
          },
          home: Scaffold(body: Row(children: cards)),
        ),
      );

  testWidgets('la flèche droite passe à l\'affiche suivante', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(app(cards: [
      TvFocusable(
        focusNode: first,
        onSelect: () {},
        child: const SizedBox(width: 100, height: 100),
      ),
      TvFocusable(
        focusNode: second,
        onSelect: () {},
        child: const SizedBox(width: 100, height: 100),
      ),
    ]));
    first.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(second.hasFocus, isTrue);
  });

  // Les cartes traitent OK elles-mêmes ; ce qui en dépend, ce sont les
  // contrôles qui ne sont pas des boutons — un interrupteur des réglages.
  testWidgets('OK bascule un interrupteur, qui n\'est pas un bouton',
      (tester) async {
    var on = false;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(app(cards: [
      StatefulBuilder(
        builder: (context, setState) => Switch(
          focusNode: node,
          value: on,
          onChanged: (value) => setState(() => on = value),
        ),
      ),
    ]));
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(on, isTrue);
  });
}
