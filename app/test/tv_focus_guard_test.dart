import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus_guard.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Le défaut que ce garde-fou couvre : sur un téléviseur, quand le widget qui
/// avait le focus disparaît, plus rien ne répond à la télécommande. Revenir
/// d'un film recharge l'accueil et détruit la vignette focalisée — c'est
/// exactement ce cas.
void main() {
  test('un conteneur qui détient le focus veut dire « personne »', () {
    // Flutter fait remonter le focus au conteneur le plus proche quand le nœud
    // focalisé est détruit. C'est l'état où les flèches sont sans effet, et
    // c'est ce qu'il faut savoir reconnaître.
    expect(focusIsStranded(FocusScopeNode()), isTrue);
  });

  test('pas de focus du tout compte aussi', () {
    expect(focusIsStranded(null), isTrue);
  });

  test('un élément actionnable ne déclenche rien', () {
    // Un nœud ordinaire est quelque chose que l'utilisateur peut activer : il
    // ne faut surtout pas lui reprendre le focus.
    expect(focusIsStranded(FocusNode()), isFalse);
  });

  testWidgets('le garde-fou laisse passer les enfants', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TvFocusGuard(child: Text('accueil', textDirection: TextDirection.ltr)),
      ),
    );
    expect(find.text('accueil'), findsOneWidget);
  });

  // Quand la page perd le focus du navigateur — sur un téléviseur LG, un clic
  // du pointeur hors de l'app, ou dans le simulateur un clic sur sa
  // télécommande —, Flutter gare le focus à la racine : plus aucune flèche
  // n'avait d'effet, et le garde-fou levait une exception à chaque frame.
  group('focus garé par la vue', () {
    setUp(() => TvMode.enabled.value = true);
    tearDown(() => TvMode.enabled.value = false);

    Future<List<FocusNode>> pumpRow(WidgetTester tester) async {
      final nodes = [FocusNode(), FocusNode()];
      for (final node in nodes) {
        addTearDown(node.dispose);
      }
      await tester.pumpWidget(TvFocusGuard(
        child: MaterialApp(
          home: Row(children: [
            for (final node in nodes)
              Focus(
                  focusNode: node,
                  child: const SizedBox(width: 50, height: 50)),
          ]),
        ),
      ));
      return nodes;
    }

    void park() => FocusManager.instance.rootScope.requestScopeFocus();

    test('la racine sans arbre de widgets est reconnue', () {
      expect(focusIsParked(FocusManager.instance.rootScope), isTrue);
      expect(focusIsParked(FocusScopeNode()), isTrue);
      expect(focusIsParked(FocusNode()), isFalse);
    });

    testWidgets("la première touche rend le focus à l'élément qui l'avait",
        (tester) async {
      final nodes = await pumpRow(tester);
      nodes[1].requestFocus();
      await tester.pump();

      park();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
          FocusManager.instance.primaryFocus, FocusManager.instance.rootScope);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(nodes[1].hasPrimaryFocus, isTrue);
    });

    testWidgets('hors téléviseur, le focus garé reste garé', (tester) async {
      final nodes = await pumpRow(tester);
      nodes[0].requestFocus();
      await tester.pump();
      TvMode.enabled.value = false;

      park();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(nodes[0].hasFocus, isFalse);
    });
  });
}
