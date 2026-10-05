/// Lecture native du marqueur d'origine — voir `install_origin.dart`.
///
/// Chaque plateforme range la provenance de l'installeur ailleurs (ADR-0042),
/// mais toutes rendent ici la même chose : un texte portant une ligne
/// `HostUrl=<adresse du téléchargement>`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'install_origin_formats.dart';

/// Le nom du marqueur, posé par l'installeur Windows et glissé dans le bundle
/// iOS par le serveur (`MarkerFile` dans `server/installorigin`).
const _markerFile = 'install-origin.txt';

Future<String?> readInstallOriginMarker() async {
  // Sous `flutter test`, le poste du développeur a souvent Onyx installé : son
  // marqueur ne doit pas décider de l'adresse par défaut d'un test.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;

  if (Platform.isWindows) return _readWindows();
  if (Platform.isAndroid) return _readAndroid();
  if (Platform.isMacOS) return _readMacOS();
  // iOS, et tvOS que flutter-tvos annonce sous son propre nom.
  if (Platform.isIOS || Platform.operatingSystem == 'tvos') return _readBundle();
  return null;
}

/// Windows : le `Zone.Identifier` que l'installeur Inno a recopié
/// (`app/installer.iss`, `SaveInstallOrigin`).
///
/// Dans `ProgramData` et non à côté d'`app.exe` : une mise à jour déplace tout
/// le dossier de l'app dans `.update-old-*` (ADR-0030) et l'emporterait.
Future<String?> _readWindows() async {
  final programData = Platform.environment['ProgramData'];
  if (programData == null || programData.isEmpty) return null;
  return _readText(File('$programData\\Onyx\\$_markerFile'));
}

/// iOS et tvOS : un fichier du bundle, ajouté à l'IPA par le serveur.
Future<String?> _readBundle() =>
    _readText(File('${File(Platform.resolvedExecutable).parent.path}/$_markerFile'));

Future<String?> _readText(File file) async {
  if (!await file.exists()) return null;
  // Écrit sans encodage déclaré : une adresse mal décodée est rejetée plus
  // loin, elle ne doit pas lever ici.
  return utf8.decode(await file.readAsBytes(), allowMalformed: true);
}

/// Android : une paire de l'« APK Signing Block » de notre propre APK, écrite
/// par le serveur. Seules la fin du fichier et le bloc sont lus, pas les
/// 150 Mo de l'APK.
Future<String?> _readAndroid() async {
  final path =
      await const MethodChannel('onyx/device').invokeMethod<String>('apkPath');
  if (path == null) return null;

  final apk = await File(path).open();
  try {
    final size = await apk.length();
    final tailLength = math.min(size, zipTailLength);
    await apk.setPosition(size - tailLength);
    final directory = zipCentralDirectoryOffset(await apk.read(tailLength));
    if (directory == null || directory < apkSigningBlockFooterLength) {
      return null;
    }

    await apk.setPosition(directory - apkSigningBlockFooterLength);
    final blockSize =
        apkSigningBlockSize(await apk.read(apkSigningBlockFooterLength));
    if (blockSize == null || blockSize > directory) return null;

    await apk.setPosition(directory - blockSize);
    final pairs = await apk.read(blockSize - apkSigningBlockFooterLength);
    final value = apkSigningBlockValue(pairs, apkOriginBlockId);
    return value == null ? null : utf8.decode(value, allowMalformed: true);
  } finally {
    await apk.close();
  }
}

/// macOS : le système marque toute app téléchargée d'un attribut de
/// quarantaine, et range l'adresse du téléchargement dans sa base des
/// événements de quarantaine, sous l'identifiant que porte l'attribut. Le DMG
/// n'a donc pas besoin d'être modifié, et l'attribut suit l'app quand on la
/// glisse dans Applications.
///
/// `xattr` et `sqlite3` sont livrés avec macOS ; l'app n'est pas sandboxée
/// (`Release.entitlements`), elle peut les lancer.
Future<String?> _readMacOS() async {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;

  final attribute = await Process.run(
    '/usr/bin/xattr',
    ['-p', 'com.apple.quarantine', Platform.resolvedExecutable],
  );
  if (attribute.exitCode != 0) return null;
  final event = quarantineEventId(attribute.stdout as String);
  if (event == null) return null;

  final query = await Process.run('/usr/bin/sqlite3', [
    '-readonly',
    '$home/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2',
    'SELECT LSQuarantineDataURLString FROM LSQuarantineEvent '
        "WHERE LSQuarantineEventIdentifier = '$event' LIMIT 1",
  ]);
  if (query.exitCode != 0) return null;
  final url = (query.stdout as String).trim();
  return url.isEmpty ? null : 'HostUrl=$url';
}
