@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Écrans autorisés à garder une minuterie périodique hors de la vue, et
/// pourquoi.
///
/// La liste doit rester courte, et chaque entrée doit s'expliquer. Y ajouter un
/// fichier « pour que le test passe » est exactement ce que ce test existe pour
/// empêcher.
const Map<String, String> _allowed = {
  'lib/screens/player/player_screen_startup.dart':
      'la lecture continue fenêtre réduite : le relais par un autre serveur '
          'doit rester possible',
  'lib/screens/auth/login_screen.dart':
      'attend la validation faite sur le téléphone, souvent app réduite',
  'lib/screens/auth/phone_sign_in_panel.dart':
      'attend la validation faite sur le téléphone, souvent app réduite',
  'lib/widgets/global/app_update_dialog.dart':
      'compte à rebours d\'une seconde avant le redémarrage de la mise à jour',
};

/// Le source de la bibliothèque à laquelle [file] appartient : le sien, ou
/// celui du fichier nommé par son `part of`.
String _libraryOf(File file, String source) {
  final owner = RegExp(r'''^part of ['"]([^'"]+)['"];''', multiLine: true)
      .firstMatch(source);
  if (owner == null) return source;
  final parent = File.fromUri(file.absolute.uri.resolve(owner.group(1)!));
  return parent.existsSync() ? parent.readAsStringSync() : source;
}

void main() {
  // Une minuterie posée dans `initState` tourne tant que le widget existe :
  // sous le lecteur, dans un onglet caché, fenêtre réduite. C'est ce qui
  // gardait l'app éveillée — et le Mac chaud — sans que rien ne bouge à
  // l'écran. `OnScreenState` la démarre et l'arrête avec la vue.
  test('aucun écran ne sonde en boucle quand on ne le voit pas', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final source = entity.readAsStringSync();
      if (!source.contains('Timer.periodic(')) continue;
      // Un fichier `part` appartient à sa bibliothèque : c'est elle qui dit
      // s'il s'agit d'un écran.
      final library = _libraryOf(entity, source);
      if (!library.contains('extends State<')) continue;
      if (library.contains('OnScreenState')) continue;
      // La liste blanche est écrite en barres obliques ; Windows rend des
      // barres inverses.
      final path = entity.path.replaceAll('\\', '/');
      if (_allowed.containsKey(path)) continue;
      offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Ces écrans lancent un Timer.periodic qui continue hors de la '
          'vue (page recouverte, onglet caché, fenêtre réduite) : chaque tour '
          'réveille l\'app et reconstruit des widgets que personne ne voit. '
          'Démarrez-le dans `didChangeOnScreen` avec le mixin `OnScreenState` '
          '(lib/utils/on_screen.dart), ou ajoutez le fichier à la liste '
          'blanche avec sa raison.',
    );
  });

  test('la liste blanche ne garde que des fichiers qui existent', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path a disparu');
    }
  });
}
