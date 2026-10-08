@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fichiers autorisés à garder un `catch` vide, et pourquoi.
///
/// La liste doit rester courte, et chaque entrée doit s'expliquer. Y ajouter un
/// fichier « pour que le test passe » est exactement ce que ce test existe pour
/// empêcher.
const Map<String, String> _allowed = {
  'lib/screens/player/web/web_playback_web.dart':
      'JavaScript embarqué dans une chaîne, pas du Dart',
};

/// Un bloc qui avale une erreur sans rien dedans : ni instruction, ni
/// commentaire. Trois écritures : `catch (e) {}`, `on Foo {}` et
/// `.catchError((e) {})`.
final List<RegExp> _silent = [
  RegExp(r'\bcatch\s*\([^)]*\)\s*\{\s*\}'),
  RegExp(r'\bon\s+[A-Z][\w.<>?, ]*\{\s*\}'),
  RegExp(r'\bcatchError\(\s*\([^)]*\)\s*(async\s*)?\{\s*\}'),
];

void main() {
  test('aucune erreur n’est avalée sans dire pourquoi', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // La liste blanche est écrite en barres obliques ; Windows rend des
      // barres inverses.
      final path = entity.path.replaceAll('\\', '/');
      if (_allowed.containsKey(path)) continue;

      final source = entity.readAsStringSync();
      for (final pattern in _silent) {
        for (final match in pattern.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          offenders.add('$path:${line + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Ces blocs avalent une erreur sans rien en faire ni dire '
          'pourquoi. Une panne qui passe par là ne laisse aucune trace : ni '
          'dans le journal exportable, ni à l’écran. Traitez-la, journalisez-la '
          '(`debugPrint`, `ClientLog.error`), ou écrivez dans le bloc le '
          'commentaire qui dit pourquoi l’ignorer est le bon choix :\n\n'
          '${offenders.join('\n')}',
    );
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
