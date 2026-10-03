@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/theme/app_type.dart';

/// Fichiers autorisés à écrire une taille de texte en chiffres, et pourquoi.
const Map<String, String> _allowed = {
  // La taille de référence des sous-titres, que le réglage de l'utilisateur
  // met à l'échelle : ce n'est pas du texte d'interface.
  'lib/screens/player/playback/subtitle_overlay.dart': 'rendu des sous-titres',
  'lib/screens/player/playback/mpv_subtitle_overlay.dart':
      'rendu des sous-titres',
};

void main() {
  test('les tailles de texte viennent de l’échelle AppType', () {
    final offenders = <String>[];
    // Une taille littérale seule — `fontSize: 13,` —, pas une taille calculée
    // depuis la hauteur d'un contrôle du lecteur.
    final literal = RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)\s*[,)\n]');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Windows rend des barres inverses ; la liste blanche est en barres
      // obliques.
      final path = entity.path.replaceAll('\\', '/');
      if (_allowed.containsKey(path)) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final match = literal.firstMatch('${lines[i]}\n');
        if (match != null) offenders.add('$path:${i + 1} : ${match.group(1)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Une taille décidée sur place, c’est une voix de plus dans '
          'l’app. Prends la marche voisine dans lib/theme/app_type.dart, ou '
          'ajoute-la à l’échelle avec son rôle :\n\n${offenders.join('\n')}',
    );
  });

  test('l’échelle monte strictement et sans demi-taille', () {
    for (var i = 0; i < AppType.scale.length; i++) {
      final size = AppType.scale[i];
      expect(size, size.roundToDouble(), reason: '$size n’est pas entière');
      if (i > 0) expect(size, greaterThan(AppType.scale[i - 1]));
    }
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
