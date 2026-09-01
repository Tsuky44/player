@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fichiers autorisés à contenir un champ nu, et pourquoi.
///
/// La liste doit rester courte, et chaque entrée doit s'expliquer. Y ajouter un
/// fichier « pour que le test passe » est exactement ce que ce test existe pour
/// empêcher.
const Map<String, String> _allowed = {
  // Le champ de `GlassSearchInput` est enveloppé par son appelant
  // (`GlassCatalogSearch`), qui possède le nœud et l'état de la recherche.
  'lib/widgets/global/glass_chrome.dart':
      'enveloppé par GlassCatalogSearch, qui détient le nœud',
  // L'exemple de la documentation du widget lui-même.
  'lib/tv/tv_deferred_keyboard.dart': 'exemple dans la doc du widget',
};

void main() {
  test('aucun champ de saisie n’échappe à TvDeferredKeyboard', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final source = entity.readAsStringSync();
      final fields =
          RegExp(r'\b(TextField|TextFormField)\(').allMatches(source).length;
      if (fields == 0) continue;

      final wrapped = 'canRequestFocus) =>'.allMatches(source).length;
      if (wrapped >= fields) continue;
      if (_allowed.containsKey(entity.path)) continue;

      offenders.add('${entity.path} : $fields champ(s), $wrapped enveloppé(s)');
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Sur un téléviseur, un champ qui prend le focus fait ouvrir le '
          'clavier plein écran d’Android, et tout ce qui suit dans le parcours '
          'devient inatteignable. Chaque champ doit passer par '
          'TvDeferredKeyboard :\n\n'
          '${offenders.join('\n')}\n\n'
          'Voir lib/tv/tv_deferred_keyboard.dart.',
    );
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    // Une exception qui survit à la disparition de son fichier est une porte
    // laissée ouverte pour un fichier futur qui portera le même nom.
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
