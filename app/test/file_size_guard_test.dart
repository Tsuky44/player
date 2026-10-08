@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Au-delà, un fichier porte plusieurs responsabilités : il se découpe avant
/// de grossir. Voir `.claude/skills/onyx-engineering/SKILL.md` et l'ADR-0052.
const int _maxLines = 800;

/// Fichiers déjà au-dessus de la limite, avec le nombre de lignes qu'ils ne
/// doivent plus dépasser, et pourquoi ils y sont encore.
///
/// La liste ne fait que rétrécir. Un fichier qui y figure ne grossit plus ; un
/// fichier repassé sous la limite en sort. Y relever un plafond « pour que le
/// test passe » est exactement ce que ce test existe pour empêcher : sortez
/// d'abord dans son propre fichier le morceau que vous touchez.
const Map<String, (int ceiling, String why)> _grandfathered = {
  'lib/screens/player/widgets/onyx/onyx_controls_layer.dart': (
    1049,
    'le Chrome Onyx et ses boutons ; ses rangées restent à extraire',
  ),
  'lib/services/download_manager_io.dart': (
    1218,
    'une seule classe pour la file d’attente, le disque et la reprise',
  ),
  'lib/screens/settings/servers_screen.dart': (
    958,
    'deux écrans dans un fichier : la liste des serveurs et l’ajout',
  ),
  'lib/screens/library/show_detail_screen.dart': (
    868,
    'la fiche série entière dans une seule classe d’état',
  ),
  'lib/screens/settings/widgets/settings_ui.dart': (
    866,
    'quinze widgets de réglages ; à ranger par famille',
  ),
  'lib/screens/player/playback/mpv_playback_session.dart': (
    801,
    'au seuil : le prochain ajout commence par une extraction',
  ),
};

/// Fichiers que la limite ne concerne pas, et pourquoi.
const Map<String, String> _exempt = {
  'lib/l10n/en.dart':
      'une table de traductions : elle grandit d’une ligne par phrase',
};

int _lineCount(File file) => file.readAsLinesSync().length;

void main() {
  test('aucun fichier ne dépasse $_maxLines lignes', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // La liste est écrite en barres obliques ; Windows rend des barres
      // inverses.
      final path = entity.path.replaceAll('\\', '/');
      if (_exempt.containsKey(path)) continue;
      final lines = _lineCount(entity);
      final known = _grandfathered[path];
      if (known == null) {
        if (lines > _maxLines) offenders.add('$path : $lines lignes');
      } else if (lines > known.$1) {
        offenders.add('$path : $lines lignes, plafond ${known.$1}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Un fichier de cette taille ne se relit plus d’un bloc, et '
          'chaque changement y croise tous les autres : `player_screen.dart` '
          'en était à 3 200 lignes quand il a fallu le découper. Sortez dans '
          'son propre fichier (widget, hook, service, fichier `part` par '
          'sujet) le morceau que vous touchez, puis modifiez-le là :\n\n'
          '${offenders.join('\n')}',
    );
  });

  test('la liste des fichiers tolérés ne fait que rétrécir', () {
    for (final path in _exempt.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
    for (final entry in _grandfathered.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} n’existe plus');
      expect(
        _lineCount(file),
        greaterThan(_maxLines),
        reason: '${entry.key} est repassé sous $_maxLines lignes : retirez-le '
            'de la liste, pour qu’il ne puisse plus y remonter.',
      );
    }
  });
}
