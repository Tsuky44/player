import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/install_origin.dart';
import 'package:onyx/services/install_origin_formats.dart';

/// Les formats où le serveur et les systèmes rangent l'origine de l'installeur
/// — ADR-0042. Le pendant serveur est `server/installorigin`.
void main() {
  Uint8List pair(int id, List<int> value) {
    final bytes = ByteData(12)
      ..setUint64(0, 4 + value.length, Endian.little)
      ..setUint32(8, id, Endian.little);
    return Uint8List.fromList([...bytes.buffer.asUint8List(), ...value]);
  }

  Uint8List endRecord({required int directoryOffset, String comment = ''}) {
    final bytes = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint32(16, directoryOffset, Endian.little)
      ..setUint16(20, comment.length, Endian.little);
    return Uint8List.fromList(
        [...bytes.buffer.asUint8List(), ...ascii.encode(comment)]);
  }

  group('fin de ZIP', () {
    test('le décalage du répertoire central est lu dans l\'enregistrement', () {
      final tail = Uint8List.fromList(
          [...List.filled(40, 7), ...endRecord(directoryOffset: 1234)]);
      expect(zipCentralDirectoryOffset(tail), 1234);
    });

    test('un commentaire ne décale pas la lecture', () {
      final tail = endRecord(directoryOffset: 99, comment: 'signature');
      expect(zipCentralDirectoryOffset(tail), 99);
    });

    test('ni un ZIP64 ni autre chose qu\'un ZIP ne donnent de décalage', () {
      expect(zipCentralDirectoryOffset(endRecord(directoryOffset: 0xFFFFFFFF)),
          isNull);
      expect(zipCentralDirectoryOffset(Uint8List(64)), isNull);
      expect(zipCentralDirectoryOffset(Uint8List(3)), isNull);
    });
  });

  group('APK Signing Block', () {
    Uint8List footer(int size, {String magic = 'APK Sig Block 42'}) {
      final bytes = ByteData(8)..setUint64(0, size, Endian.little);
      return Uint8List.fromList(
          [...bytes.buffer.asUint8List(), ...ascii.encode(magic)]);
    }

    test('la taille du bloc n\'est lue que derrière sa magie', () {
      expect(apkSigningBlockSize(footer(4096)), 4096);
      expect(apkSigningBlockSize(footer(4096, magic: 'not a sig block!')),
          isNull);
      expect(apkSigningBlockSize(footer(8)), isNull);
    });

    test('la paire d\'Onyx est retrouvée parmi celles de la signature', () {
      final pairs = Uint8List.fromList([
        ...pair(0x7109871a, List.filled(300, 1)),
        ...pair(apkOriginBlockId, utf8.encode('HostUrl=https://a/b\n')),
        ...pair(0x42726577, List.filled(50, 0)),
      ]);
      expect(utf8.decode(apkSigningBlockValue(pairs, apkOriginBlockId)!),
          'HostUrl=https://a/b\n');
    });

    test('un APK qui ne vient pas du serveur n\'a pas de paire', () {
      expect(
          apkSigningBlockValue(
              pair(0x7109871a, List.filled(20, 1)), apkOriginBlockId),
          isNull);
      expect(apkSigningBlockValue(Uint8List(0), apkOriginBlockId), isNull);
    });

    test('un bloc tronqué ne fait pas lire hors des limites', () {
      final whole = pair(apkOriginBlockId, utf8.encode('HostUrl=https://a'));
      expect(
          apkSigningBlockValue(
              Uint8List.sublistView(whole, 0, whole.length - 3),
              apkOriginBlockId),
          isNull);
    });
  });

  group('quarantaine macOS', () {
    test('l\'identifiant d\'événement est le quatrième champ', () {
      expect(
        quarantineEventId(
            '0083;65a1b2c3;Safari;f3a1c2d4-0b1e-4c5d-9e8f-0123456789ab\n'),
        'F3A1C2D4-0B1E-4C5D-9E8F-0123456789AB',
      );
    });

    test('tout ce qui n\'est pas un UUID est refusé', () {
      expect(quarantineEventId('0083;65a1b2c3;Safari;'), isNull);
      expect(quarantineEventId('0083;65a1b2c3'), isNull);
      expect(quarantineEventId("0083;65a1b2c3;Safari;' OR 1=1 --"), isNull);
    });
  });

  // Vérification de bout en bout, à la demande : un APK annoté par le serveur
  // (`installorigin.Stamp`) est relu par les fonctions de l'app.
  //   ONYX_STAMPED_APK=chemin\vers\annote.apk flutter test test/install_origin_formats_test.dart
  final stamped = Platform.environment['ONYX_STAMPED_APK'];
  test('un APK annoté par le serveur est relu par l\'app', () {
    final apk = File(stamped!).openSync();
    addTearDown(apk.closeSync);

    final size = apk.lengthSync();
    final tailLength = size < zipTailLength ? size : zipTailLength;
    apk.setPositionSync(size - tailLength);
    final directory = zipCentralDirectoryOffset(apk.readSync(tailLength))!;

    apk.setPositionSync(directory - apkSigningBlockFooterLength);
    final blockSize =
        apkSigningBlockSize(apk.readSync(apkSigningBlockFooterLength))!;

    apk.setPositionSync(directory - blockSize);
    final pairs = apk.readSync(blockSize - apkSigningBlockFooterLength);
    final marker = utf8.decode(apkSigningBlockValue(pairs, apkOriginBlockId)!);

    expect(InstallOrigin.serverUrlFromMarker(marker), isNotNull);
  }, skip: stamped == null ? 'ONYX_STAMPED_APK non défini' : false);
}
