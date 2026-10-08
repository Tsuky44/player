@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fichiers hors `*_io.dart` autorisés à importer `dart:io`, et pourquoi.
///
/// La liste doit rester courte, et chaque entrée doit s'expliquer. Y ajouter un
/// fichier « pour que le test passe » est exactement ce que ce test existe pour
/// empêcher.
const Map<String, String> _allowed = {};

void main() {
  test('dart:io et Platform.isX ne sortent pas des fichiers _io', () {
    final offenders = <String>[];
    final ioImport = RegExp(r'''^\s*import\s+['"]dart:io['"]''');
    // `AppPlatform.isX` est la façade : seul le `Platform` nu de dart:io
    // compte.
    final rawPlatform =
        RegExp(r'(?<![A-Za-z_.])Platform\.(is[A-Z]\w*|operatingSystem)');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('_io.dart')) continue;
      // La liste blanche est écrite en barres obliques ; Windows rend des
      // barres inverses.
      final path = entity.path.replaceAll('\\', '/');
      if (_allowed.containsKey(path)) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Un commentaire peut nommer ce qu'il déconseille.
        if (line.trimLeft().startsWith('//')) continue;
        if (ioImport.hasMatch(line) || rawPlatform.hasMatch(line)) {
          offenders.add('$path:${i + 1} : ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '`dart:io` ne compile pas pour le web : un seul import hors '
          'd’un fichier `_io.dart` casse la version navigateur, que ni '
          '`flutter analyze` ni `flutter test` ne construisent. Un '
          '`Platform.isX` dispersé oublie aussi l’Apple TV, où '
          '`Platform.isIOS` répond vrai. Passez par '
          '`AppPlatform` (lib/utils/app_platform.dart) et `TvMode`, ou par un '
          'trio `x.dart` / `x_io.dart` / `x_web.dart` :\n\n'
          '${offenders.join('\n')}',
    );
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
