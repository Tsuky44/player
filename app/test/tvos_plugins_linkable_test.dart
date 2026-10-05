@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tout plugin qui se déclare tvOS embarque un dossier tvos/', () {
    final config = File('.dart_tool/package_config.json');
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map<String, dynamic>)['packages']
            as List<dynamic>;

    final offenders = <String>[];
    for (final package in packages.cast<Map<String, dynamic>>()) {
      // Les chemins relatifs le sont par rapport à `.dart_tool/`.
      final root = Directory.fromUri(
        config.absolute.uri.resolve(package['rootUri'] as String),
      );
      final pubspec = File('${root.path}/pubspec.yaml');
      if (!pubspec.existsSync()) continue;

      final declaresTvos = RegExp(r'^\s+tvos:\s*$', multiLine: true)
          .hasMatch(pubspec.readAsStringSync());
      if (!declaresTvos) continue;
      if (Directory('${root.path}/tvos').existsSync()) continue;

      offenders.add(package['name'] as String);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'flutter-tvos inscrit dans GeneratedPluginRegistrant.m tout '
          'plugin qui déclare la plateforme `tvos`, mais ne sait lier que le '
          'code natif rangé sous `tvos/` (Package.swift ou podspec). Un plugin '
          'qui déclare tvOS depuis son dossier `ios/` casse le build Apple TV '
          'sur « Module not found » (wakelock_plus 1.8.0) :\n\n'
          '${offenders.join('\n')}\n\n'
          'Épingle le paquet sous la version qui a ajouté tvOS, ou passe à son '
          'portage `_tvos`. Voir ADR-0028 et pubspec.yaml.',
    );
  });
}
