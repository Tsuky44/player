import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/settings/legal_document_screen.dart';
import 'package:onyx/screens/settings/widgets/about_group.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: AboutGroup())),
      ));

  // Ce que les magasins et les conditions de TMDB exigent de lire dans l'app.
  testWidgets('À propos porte l’attribution TMDB et le rappel de responsabilité',
      (tester) async {
    await pump(tester);

    expect(find.textContaining(AboutGroup.tmdbAttribution), findsOneWidget);
    expect(find.textContaining(AboutGroup.responsibility), findsOneWidget);
    expect(find.text('Licences open source'), findsOneWidget);
  });

  testWidgets('la politique de confidentialité s’ouvre dans l’app',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text(LegalDocument.privacy.title));
    await tester.pumpAndSettle();

    expect(find.byType(LegalDocumentScreen), findsOneWidget);
    expect(find.textContaining('ne reçoit, ne stocke et ne vend aucune donnée'),
        findsOneWidget);
  });

  // Lu sur le disque : `rootBundle` ne répond pas hors d'un `testWidgets`.
  test('chaque document légal est un fichier du dossier embarqué', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/legal/'));
    for (final document in LegalDocument.values) {
      expect(File(document.asset).readAsStringSync().trim(), isNotEmpty,
          reason: document.asset);
    }
    expect(File('assets/legal/third_party.txt').readAsStringSync(),
        contains('LGPL'));
  });
}
