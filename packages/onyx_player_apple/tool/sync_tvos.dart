// Tient la copie Apple TV des sources Swift identique à celle d'iOS et macOS.
//
// flutter-tvos ne lit que `tvos/Package.swift`, et un paquet Swift ne peut pas
// désigner des sources hors de son dossier. Un lien symbolique réglerait ça,
// mais il ne survit pas à un dépôt cloné sous Windows : c'est donc une copie,
// écrite par ce script et vérifiée par
// `app/test/onyx_player_apple_sources_test.dart`.
//
// Le script corrige aussi la garde d'import de Pigeon, qui n'importe `Flutter`
// que sous `os(iOS)` : sur l'Apple TV, le module manquerait.
//
// À lancer depuis `packages/onyx_player_apple`, après chaque génération Pigeon
// ou modification d'un fichier Swift :
//
//   dart run tool/sync_tvos.dart

import 'dart:io';

const sourceDir = 'darwin/onyx_player_apple/Sources/onyx_player_apple';
const tvosDir = 'tvos/Sources/onyx_player_apple';
const pigeonImportGuard = '#if os(iOS)\n  import Flutter';
const appleImportGuard = '#if os(iOS) || os(tvOS)\n  import Flutter';

void main() {
  final source = Directory(sourceDir);
  if (!source.existsSync()) {
    stderr.writeln('Introuvable : $sourceDir. Lancer depuis packages/onyx_player_apple.');
    exitCode = 1;
    return;
  }

  final generated = File('$sourceDir/Messages.g.swift');
  final text = generated.readAsStringSync().replaceAll('\r\n', '\n');
  if (text.contains(pigeonImportGuard)) {
    generated.writeAsStringSync(
        text.replaceFirst(pigeonImportGuard, appleImportGuard));
    stdout.writeln('Garde d\'import de Pigeon étendue à tvOS.');
  }

  final target = Directory(tvosDir);
  if (target.existsSync()) target.deleteSync(recursive: true);
  target.createSync(recursive: true);
  for (final file in source.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    file.copySync('$tvosDir/$name');
    stdout.writeln('→ $tvosDir/$name');
  }
}
