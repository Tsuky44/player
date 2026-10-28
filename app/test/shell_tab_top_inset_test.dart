import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/desktop_window.dart';

/// Les onglets du shell laissent la place de la barre qui flotte au-dessus
/// d'eux. « Demander » et « Listes » mettaient 28 sur téléphone : leur titre
/// passait sous la barre de recherche.
void main() {
  Future<double> insetAt(
    WidgetTester tester,
    Size size, {
    required bool embedded,
  }) async {
    late double inset;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) {
          inset = shellTabTopInset(context, embedded: embedded);
          return const SizedBox();
        }),
      ),
    );
    return inset;
  }

  testWidgets('sur téléphone, un onglet descend sous la barre du haut',
      (tester) async {
    final inset = await insetAt(tester, const Size(411, 900), embedded: false);
    // Barre d'état (0 en test) + 56 : jamais le 28 d'avant.
    expect(inset, 56);
  });

  testWidgets('sur tablette sans barre desktop, la marge reste fixe',
      (tester) async {
    final inset = await insetAt(tester, const Size(700, 900), embedded: false);
    expect(inset, 48);
  });

  testWidgets('avec la barre de verre desktop, la marge suit sa hauteur',
      (tester) async {
    late double expected;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late double inset;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) {
          inset = shellTabTopInset(context, embedded: true);
          expected = embeddedShellContentTopInset(context);
          return const SizedBox();
        }),
      ),
    );
    expect(inset, expected);
  });
}
