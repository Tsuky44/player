@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/theme/app_theme.dart';

/// Les promesses de l'ADR-0025 sur la police : elle est dans le paquet, et
/// personne ne la redemande au réseau.
void main() {
  test('aucun fichier ne passe plus par google_fonts', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('package:google_fonts/') ||
          source.contains('GoogleFonts.')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'La police est embarquée (assets/fonts). Un appel à google_fonts '
          'remet une requête réseau entre le lancement et le premier texte, et '
          'rend une application hors ligne dépendante de fonts.gstatic.com. '
          'Voir docs/adr/0025-poids-de-l-interface-sous-windows.md.',
    );
  });

  test('la déclaration du pubspec pointe sur des fichiers qui existent', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('google_fonts:'), isFalse,
        reason: 'La dépendance a été retirée avec l\'ADR-0025.');

    final assets = RegExp(r'asset: (assets/fonts/[^\s]+)')
        .allMatches(pubspec)
        .map((m) => m.group(1)!)
        .toList();
    expect(assets, isNotEmpty);
    for (final asset in assets) {
      expect(File(asset).existsSync(), isTrue, reason: '$asset est déclaré '
          'mais absent : la police tomberait silencieusement sur celle du '
          'système.');
    }
  });

  test('le thème nomme la police embarquée, et ne se reconstruit pas', () {
    final theme = AppTheme.dark;
    expect(theme.textTheme.bodyMedium?.fontFamily, AppTheme.fontFamily);
    // Une autre instance à chaque lecture ferait reconstruire tout ce qui lit
    // `Theme.of(context)`.
    expect(identical(AppTheme.dark, theme), isTrue);
  });

  testWidgets('un texte sans style hérite de la police', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(body: Text('Onyx')),
    ));
    final style = tester.widget<RichText>(find.byType(RichText)).text.style;
    expect(style?.fontFamily, AppTheme.fontFamily);
  });
}
