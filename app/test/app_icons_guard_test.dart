@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Les dossiers de l'interface de navigation, qui ne lisent leurs icônes que
/// dans `AppIcons`.
const List<String> _browsingDirs = [
  'lib/screens/shell',
  'lib/screens/home',
  'lib/screens/library',
  'lib/screens/requests',
  'lib/screens/downloads',
  'lib/widgets/global',
];

/// Fichiers de ces dossiers autorisés à garder Material, et pourquoi.
const Map<String, String> _allowed = {
  // Le chrome du lecteur : ses icônes appartiennent aux skins
  // (`models/player_layout.dart`), pas à la navigation.
  'lib/widgets/global/control_chrome.dart': 'chrome du lecteur, skins à part',
};

void main() {
  test('la navigation ne mélange pas Material et le jeu d’icônes de l’app', () {
    final offenders = <String>[];
    final material = RegExp(r'\bIcons\.[a-zA-Z_0-9]+');

    for (final dir in _browsingDirs) {
      for (final entity in Directory(dir).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Windows rend des barres inverses ; la liste blanche est en barres
        // obliques.
        final path = entity.path.replaceAll('\\', '/');
        if (_allowed.containsKey(path)) continue;
        final hits = material
            .allMatches(entity.readAsStringSync())
            .map((m) => m.group(0))
            .toSet();
        if (hits.isNotEmpty) offenders.add('$path : ${hits.join(', ')}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Un jeu d’icônes se lit à sa cohérence : une seule icône Material '
          'au trait épais au milieu des icônes fines suffit à faire « app '
          'Android ». Prends ou ajoute l’icône dans lib/theme/app_icons.dart :'
          '\n\n${offenders.join('\n')}',
    );
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
