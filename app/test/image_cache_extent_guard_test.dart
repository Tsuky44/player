@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Listes paresseuses autorisées à garder la marge de Flutter, et pourquoi.
///
/// La liste doit rester courte, et chaque entrée doit s'expliquer : une liste
/// qui dessine des images et qui y figure, c'est une affiche qui apparaîtra en
/// retard à chaque défilement.
const Map<String, String> _allowed = {
  'lib/widgets/global/skeleton.dart': 'des espaces réservés, aucune image',
  'lib/screens/requests/widgets/season_selector_dialog.dart':
      'une liste de saisons en texte, aucune image',
  'lib/screens/requests/widgets/request_filters_sheet.dart':
      'grille en shrinkWrap sans défilement : tout est construit d’emblée',
};

/// Les constructeurs de listes qui ne construisent que ce qui est visible.
final RegExp _lazyScrollView = RegExp(
  r'\b(CustomScrollView|ListView\.builder|ListView\.separated|'
  r'GridView\.builder)\(',
);

/// Le texte des arguments de l'appel qui s'ouvre à [open], parenthèses
/// équilibrées.
String _callArguments(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return source.substring(open, i);
  }
  return source.substring(open);
}

void main() {
  test('chaque liste d’images construit une fenêtre d’avance', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      // Le lecteur et les réglages ne font défiler aucune affiche.
      if (path.startsWith('lib/screens/player/') ||
          path.startsWith('lib/screens/settings/')) {
        continue;
      }
      if (_allowed.containsKey(path)) continue;

      final source = entity.readAsStringSync();
      for (final match in _lazyScrollView.allMatches(source)) {
        final args = _callArguments(source, match.end - 1);
        if (args.contains('scrollCacheExtent:')) continue;
        final line = '\n'.allMatches(source.substring(0, match.start)).length;
        offenders.add('$path:${line + 1} ${match.group(1)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Avec la marge de Flutter (250 px), une carte ne demande son '
          'image qu’en entrant à l’écran, et l’espace réservé se voit le temps '
          'du téléchargement et du décodage. Passe '
          '`scrollCacheExtent: AppLayout.imageCacheExtent(context)` :\n\n'
          '${offenders.join('\n')}\n\n'
          'Voir ADR-0088.',
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
