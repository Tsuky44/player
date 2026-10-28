@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tout flou passe par `glassBlurs` (ADR-0086).
///
/// Un flou est la dépense la plus lourde de l'interface : une copie de
/// l'écran, floutée, à chaque image. C'est ce qu'une Apple TV HD ou un
/// téléviseur LG ne tiennent pas, et ce que le mode léger retire. Un flou
/// posé sans demander `glassBlurs(context)` reviendrait sur ces appareils
/// sans que rien ne le signale, sinon une interface qui rame de nouveau.
void main() {
  test('chaque flou demande glassBlurs', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (!source.contains('ImageFilter.blur(')) continue;
      if (!source.contains('glassBlurs(')) {
        offenders.add(entity.path.replaceAll('\\', '/'));
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Ces fichiers floutent sans demander glassBlurs(context) : le '
          'flou reviendrait en mode léger. Passer par GlassBlur, ou garder '
          'le flou derrière glassBlurs(context). Voir '
          'docs/adr/0086-mode-leger-pour-les-petits-appareils.md.',
    );
  });
}
