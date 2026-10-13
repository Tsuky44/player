@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/new_episodes/new_episode_alerts.dart';

/// Ce que la tâche de fond des nouveaux épisodes exige du natif (ADR-0059).
///
/// Rien de tout cela ne casse un build quand ça manque : l'app se lance, le
/// réglage s'affiche, et la notification n'arrive simplement jamais. Ces
/// tests relisent donc les fichiers natifs.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('l’identifiant de la tâche est le même en Dart, dans l’Info.plist et '
      'dans l’AppDelegate', () {
    final quoted = '"${NewEpisodeAlerts.taskName}"';

    expect(
      read('ios/Runner/Info.plist'),
      contains('<string>${NewEpisodeAlerts.taskName}</string>'),
      reason: 'iOS refuse de planifier une tâche dont l’identifiant n’est '
          'pas dans BGTaskSchedulerPermittedIdentifiers',
    );
    expect(read('ios/Runner/Info.plist'), contains('<string>fetch</string>'),
        reason: 'sans le mode d’arrière-plan « fetch », iOS ne réveille pas '
            'l’app');
    expect(read('ios/Runner/AppDelegate.swift'), contains(quoted),
        reason: 'iOS ne remet la tâche qu’à un identifiant enregistré '
            'pendant didFinishLaunching');
  });

  test('le moteur de la tâche de fond iOS reçoit les plugins', () {
    expect(
      read('ios/Runner/AppDelegate.swift'),
      contains('WorkmanagerPlugin.setPluginRegistrantCallback'),
      reason: 'sans eux la tâche ne lit ni le carnet de serveurs ni '
          'n’affiche de notification',
    );
  });

  test('l’icône des notifications existe et survit au build release', () {
    final source =
        read('lib/services/new_episodes/new_episode_notifications.dart');
    final icon =
        RegExp(r"_androidIcon = '(\w+)'").firstMatch(source)!.group(1)!;

    expect(File('android/app/src/main/res/drawable/$icon.xml').existsSync(),
        isTrue,
        reason: 'une icône introuvable, et Android n’affiche rien');
    expect(read('android/app/src/main/res/raw/keep.xml'),
        contains('@drawable/$icon'),
        reason: 'elle n’est nommée que depuis le Dart : le réducteur de '
            'ressources la retirerait du build release');
  });

  test('le désucrage Android qu’exige flutter_local_notifications est actif',
      () {
    final gradle = read('android/app/build.gradle.kts');

    expect(gradle, contains('isCoreLibraryDesugaringEnabled = true'));
    expect(gradle, contains('coreLibraryDesugaring('));
  });
}
