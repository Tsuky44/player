import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/macos_update_signature_io.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('onyx-bundle-'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, List<int> bytes) {
    File('${root.path}/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  // Les valeurs attendues sont celles de scripts/macos_bundle_digest.py sur le
  // même bundle : la CI signe avec l'un, l'app vérifie avec l'autre.
  test('l’empreinte du bundle est celle que calcule le script de signature',
      () async {
    write('Contents/MacOS/onyx', utf8.encode('binary\n'));
    write('Contents/Info.plist', utf8.encode('<plist/>'));
    write('Contents/Resources/été.txt', utf8.encode('é'));

    expect(await bundleDigest(root.path),
        'd7235b7ef69f6c76227c48b4834615131ab8ff4327175b84258e8fee3a89bbdf');
  });

  test('un lien entre dans l’empreinte par sa cible, sans être suivi', () async {
    write('Contents/MacOS/onyx', utf8.encode('binary\n'));
    write('Contents/Info.plist', utf8.encode('<plist/>'));
    write('Contents/Resources/été.txt', utf8.encode('é'));
    Directory('${root.path}/Contents/Frameworks/F.framework')
        .createSync(recursive: true);
    Link('${root.path}/Contents/Frameworks/F.framework/Current').createSync('A');

    expect(await bundleDigest(root.path),
        '12f423e1ce9173a0da8d16b5e0526d3961baa52ea27f3e658913982c39c6ec61');
  }, skip: Platform.isWindows ? 'liens symboliques réservés à l’administrateur' : false);

  test('modifier un octet du bundle change son empreinte', () async {
    write('Contents/MacOS/onyx', utf8.encode('binary\n'));
    final before = await bundleDigest(root.path);
    write('Contents/MacOS/onyx', utf8.encode('Binary\n'));
    expect(await bundleDigest(root.path), isNot(before));
  });

  test('la version fait partie du message signé', () {
    expect(signedMessage('1.2.3', 'abc'), 'onyx-update-macos-v1\n1.2.3\nabc');
  });

  // La clé de la vérification macOS doit rester celle que la CI utilise pour
  // Windows : une rotation qui oublierait l'une refuserait toutes les mises à
  // jour de l'autre plateforme.
  test('la clé publique macOS est celle de l’updater Windows', () {
    final header =
        File('windows/updater/update_public_key.h').readAsStringSync();
    final blob = RegExp(r'0x([0-9a-f]{2})')
        .allMatches(header)
        .map((m) => int.parse(m.group(1)!, radix: 16))
        .toList();
    expect(ascii.decode(blob.sublist(0, 4)), 'ECS1');
    final spki = [
      ...hexToBytes('3059301306072a8648ce3d020106082a8648ce3d03010703420004'),
      ...blob.sublist(8, 72),
    ];
    final pem = updatePublicKeyPem
        .split('\n')
        .where((line) => line.isNotEmpty && !line.startsWith('-----'))
        .join();
    expect(base64.decode(pem), spki);
  });
}

List<int> hexToBytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
