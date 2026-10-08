@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Le lecteur n'a qu'un chrome, le Chrome Onyx, le même pour tous les comptes
/// et tous les appareils. Voir l'ADR-0048.
void main() {
  test('le lecteur ne monte qu’un chrome, le Chrome Onyx', () {
    final layers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path.replaceAll('\\', '/'))
        .where((path) => path.endsWith('_controls_layer.dart'))
        .toList();

    expect(
      layers,
      ['lib/screens/player/widgets/onyx/onyx_controls_layer.dart'],
      reason: 'Une deuxième couche de contrôles, c’est un deuxième lecteur : '
          'chaque correctif d’interaction (fondu, scrubber, focus TV) est '
          'alors à refaire pour chacune, et ne l’a jamais été partout. Voir '
          'docs/adr/0048-un-seul-lecteur-le-chrome-onyx.md.',
    );

    // L'écran et ses fichiers `part` : c'est une seule bibliothèque.
    final screen = Directory('lib/screens/player')
        .listSync()
        .whereType<File>()
        .where((file) => RegExp(r'[\\/]player_screen(_\w+)?\.dart$')
            .hasMatch(file.path))
        .map((file) => file.readAsStringSync())
        .join();
    final mounted = RegExp(r'\b(\w*ControlsLayer|\w*HUDOverlay)\(')
        .allMatches(screen)
        .map((match) => match.group(1))
        .toList();

    expect(
      mounted,
      ['OnyxControlsLayer'],
      reason: 'L’écran du lecteur choisit entre plusieurs chromes, ou en '
          'monte un autre que le Chrome Onyx. Il n’y a pas de préférence de '
          'chrome à lire : ni par compte, ni par appareil.',
    );
  });
}
