import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/l10n/app_language.dart';
import 'package:onyx/l10n/en.dart';
import 'package:onyx/l10n/tr.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/settings/widgets/about_group.dart';

/// Les clés littérales passées à `tr(...)` dans [source] : un ou plusieurs
/// littéraux entre apostrophes, collés par simple juxtaposition. Un `tr(x)`
/// sur une variable n'a pas de clé lisible ici, et n'est pas contrôlé.
Iterable<String> _keysIn(String source) sync* {
  final call = RegExp(r'(?<![A-Za-z0-9_.])tr\(\s*');
  for (final match in call.allMatches(source)) {
    var i = match.end;
    final key = StringBuffer();
    var found = false;
    while (i < source.length && source[i] == "'") {
      found = true;
      i++;
      while (source[i] != "'") {
        if (source[i] == r'\') {
          i++;
          key.write(switch (source[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            final other => other,
          });
        } else {
          key.write(source[i]);
        }
        i++;
      }
      i++;
      while (i < source.length && ' \t\r\n'.contains(source[i])) {
        i++;
      }
    }
    if (found) yield key.toString();
  }
}

void main() {
  tearDown(AppLanguage.resetForTest);

  // Une phrase ajoutée en français et oubliée dans le dictionnaire resterait
  // en français au milieu d'une interface anglaise, sans que rien ne casse.
  test('chaque texte passé à tr() a sa traduction anglaise', () {
    final missing = <String>{};
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.uri.path.contains('/l10n/'))) {
      for (final key in _keysIn(file.readAsStringSync())) {
        if (!kEnglish.containsKey(key)) missing.add('${file.uri.path}: $key');
      }
    }
    expect(missing, isEmpty,
        reason: 'ajoute ces clés à lib/l10n/en.dart (une entrée identique à '
            'sa clé convient pour un mot qui ne se traduit pas)');
  });

  // Un `{2}` présent en anglais et absent du français s'afficherait tel quel.
  test('une traduction ne réclame aucune valeur que sa clé n’a pas', () {
    final placeholder = RegExp(r'\{\d+\}');
    final broken = <String>[];
    kEnglish.forEach((french, english) {
      final offered = placeholder.allMatches(french).map((m) => m[0]).toSet();
      final wanted = placeholder.allMatches(english).map((m) => m[0]).toSet();
      if (!offered.containsAll(wanted)) broken.add(french);
    });
    expect(broken, isEmpty);
  });

  test('tr() rend le français tant que la langue est le français', () {
    expect(tr('Annuler'), 'Annuler');
    expect(tr('Saison {0}', [3]), 'Saison 3');
  });

  test('tr() traduit et place les valeurs quand la langue est l’anglais', () {
    AppLanguage.notifier.value = AppLanguage.english;

    expect(tr('Annuler'), 'Cancel');
    expect(tr('Saison {0}', [3]), 'Season 3');
    expect(tr('Texte absent du dictionnaire'), 'Texte absent du dictionnaire');
  });

  // Les tables constantes (langues, mois, libellés d'énumérations) ne peuvent
  // pas appeler tr() : c'est leur point d'affichage qui traduit.
  test('une table constante est traduite à l’affichage', () {
    AppLanguage.notifier.value = AppLanguage.english;

    expect(languageName('fra'), 'French');
    expect(languageName('xx'), 'XX');
  });

  testWidgets('un écran construit en anglais affiche l’anglais',
      (tester) async {
    AppLanguage.notifier.value = AppLanguage.english;
    addTearDown(AppLanguage.resetForTest);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AboutGroup())),
    ));

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('À propos'), findsNothing);
  });

  test('un appareil qui n’est pas en français reçoit l’anglais', () {
    expect(AppLanguage.forDevice(const Locale('fr', 'CA')), AppLanguage.french);
    expect(AppLanguage.forDevice(const Locale('de')), AppLanguage.english);
  });
}
