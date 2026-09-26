@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Le lecteur Apple n'a qu'un code Swift, et deux endroits où il doit vivre.
///
/// SwiftPM ne sert à Flutter que `darwin/` pour iPhone et Mac, et flutter-tvos
/// ne lit que `tvos/`. Un paquet Swift ne peut pas désigner des sources hors de
/// son dossier, et un lien symbolique ne survit pas à un clone sous Windows :
/// `tvos/` porte donc une copie, écrite par `tool/sync_tvos.dart`. Ce test
/// empêche la copie de dériver — une correction faite d'un côté seulement ne
/// se verrait que sur une Apple TV.
const _package = '../packages/onyx_player_apple';
const _darwin = '$_package/darwin/onyx_player_apple/Sources/onyx_player_apple';
const _tvos = '$_package/tvos/Sources/onyx_player_apple';

const _fix = 'Lancer `dart run tool/sync_tvos.dart` depuis '
    'packages/onyx_player_apple.';

Map<String, String> _swiftSources(String dir) => {
      for (final file in Directory(dir).listSync().whereType<File>())
        file.uri.pathSegments.last:
            file.readAsStringSync().replaceAll('\r\n', '\n'),
    };

void main() {
  test('les sources Swift de l’Apple TV sont celles d’iPhone et Mac', () {
    final darwin = _swiftSources(_darwin);
    final tvos = _swiftSources(_tvos);

    expect(tvos.keys.toSet(), darwin.keys.toSet(),
        reason: 'Les deux dossiers ne portent pas les mêmes fichiers. $_fix');
    final drifted = [
      for (final name in darwin.keys)
        if (tvos[name] != darwin[name]) name,
    ];
    expect(drifted, isEmpty,
        reason: 'Copie tvOS périmée pour ${drifted.join(', ')}. $_fix');
  });

  test('le code généré par Pigeon importe Flutter sur l’Apple TV', () {
    // Pigeon n'importe `Flutter` que sous `os(iOS)` : régénérer le contrat sans
    // repasser le script casse la compilation tvOS, et seulement elle.
    final generated = File('$_darwin/Messages.g.swift').readAsStringSync();
    expect(generated, contains('#if os(iOS) || os(tvOS)\n  import Flutter'),
        reason: 'Garde d’import de Pigeon non corrigée. $_fix');
  });

  test('les deux paquets Swift épinglent le même AetherEngine', () {
    // Un FFmpeg par build, et le même sur les trois appareils : une Apple TV
    // qui lit autrement qu'un iPhone serait un bug qu'on ne reproduit pas.
    String requirement(String manifest) {
      final source = File(manifest).readAsStringSync();
      final match = RegExp(r'AetherEngine",\s*(\.upToNextMinor\(from: "[^"]+"\))')
          .firstMatch(source);
      expect(match, isNotNull, reason: '$manifest ne dépend plus d’AetherEngine');
      return match!.group(1)!;
    }

    expect(
      requirement('$_package/tvos/Package.swift'),
      requirement('$_package/darwin/onyx_player_apple/Package.swift'),
    );
  });
}
