import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/requests/widgets/season_liquid.dart';

/// Le mouvement liquide des bulles de saisons : ressort exact aux bornes,
/// goutte qui part de la bulle quittée et se pose sur la choisie.

void main() {
  test('le ressort part de zéro, rebondit, et se pose exactement sur un', () {
    const grow = SeasonSpring.grow(span: 0.9, delay: 0.324);
    expect(grow.transform(0), 0);
    expect(grow.transform(1), 1);
    // La goutte n'a pas encore atteint la bulle : elle n'a pas bougé.
    expect(grow.transform(0.2), 0);
    // Puis elle dépasse sa largeur finale avant de s'y poser.
    final peak = [for (var i = 0; i <= 100; i++) grow.transform(i / 100)]
        .reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(1.02));
  });

  test('la bulle quittée se retracte sans attendre', () {
    const shrink = SeasonSpring.shrink(span: 0.9);
    expect(shrink.transform(0.1), greaterThan(0.05));
    expect(shrink.transform(1), 1);
  });

  test('la goutte part de la bulle quittée et finit sur la choisie', () {
    final plan = SeasonDropPlan(origin: 100, target: 400, span: 0.9);

    final start = plan.shapes(0.001, 400, 24).first.center.dx;
    expect((start - 100).abs(), lessThan(6));

    final end = plan.shapes(0.9, 400, 24);
    expect((end.first.center.dx - 400).abs(), lessThan(0.5));
    // Deux gouttelettes de traîne, qui suivent la goutte.
    expect(end.length, 3);
    final mid = plan.shapes(0.35, 400, 24);
    expect(mid[1].center.dx, lessThan(mid.first.center.dx));
    // La goutte s'étire dans le sens du trajet quand elle va vite.
    final fastest = [
      for (var i = 1; i < 72; i++) plan.shapes(0.9 * i / 72, 400, 24).first,
    ].reduce((a, b) => a.width > b.width ? a : b);
    expect(fastest.width, greaterThan(fastest.height));
  });

  test('vers la gauche, le recul de la prise d’élan change de sens', () {
    final right = SeasonDropPlan(origin: 100, target: 400, span: 0.9);
    final left = SeasonDropPlan(origin: 400, target: 100, span: 0.9);
    expect(right.shapes(0.07, 400, 24).first.center.dx, lessThan(100));
    expect(left.shapes(0.07, 100, 24).first.center.dx, greaterThan(400));
  });

  testWidgets('le peintre dessine la goutte sans erreur à chaque instant',
      (tester) async {
    final clock = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 900),
    );
    addTearDown(clock.dispose);
    final plan = SeasonDropPlan(origin: 100, target: 400, span: 0.9);
    final painter = SeasonDropPainter(
      clock: clock,
      plan: plan,
      targetX: () => 400,
      anchorX: () => 100,
    );
    await tester.pumpWidget(
      CustomPaint(painter: painter, size: const Size(600, 48)),
    );
    for (final t in [0.0, 0.1, 0.4, 0.8, 1.0]) {
      clock.value = t;
      await tester.pump();
    }
  });
}
