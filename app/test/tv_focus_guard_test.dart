import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus_guard.dart';

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
}
