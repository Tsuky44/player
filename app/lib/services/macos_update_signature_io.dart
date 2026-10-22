import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// La signature d'une mise à jour macOS.
///
/// Le DMG venait du serveur et remplaçait l'app sans aucun contrôle, attribut
/// de quarantaine retiré : un serveur malveillant, un administrateur qui y
/// déposait un fichier, ou quiconque lisait le trafic HTTP pouvait installer
/// le programme de son choix sur chaque Mac. L'app n'étant pas signée par
/// Apple, `codesign` n'aurait rien prouvé. La signature reprend donc la clé
/// des mises à jour Windows (ADR-0030) :
///
///     empreinte = SHA-256 du manifeste du bundle Onyx.app
///     signé     = "onyx-update-macos-v1\n" + version + "\n" + empreinte (hex)
///
/// La signature ECDSA P-256 (DER) voyage dans le DMG, à côté de l'app, sous
/// [signatureFileName]. Elle est produite en CI par
/// `scripts/sign-macos-update.sh`, dont `scripts/macos_bundle_digest.py`
/// calcule le même manifeste que [bundleDigest].

/// Le fichier de signature, à la racine du volume du DMG.
const signatureFileName = '.onyx-update.sig';

/// La clé publique des mises à jour, celle de
/// `windows/updater/update_public_key.h` au format SPKI. Un test vérifie que
/// les deux restent la même clé.
const updatePublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEldi1bhmgKbM/zwwgBuiBDJ2HiFsc
CxOSYzLAjOo7j42afCmzA0kCmcxqQnreEuIodAKrlfRb99aUtHlpTjD7/Q==
-----END PUBLIC KEY-----
''';

/// Le message signé pour [version] et l'empreinte du bundle.
String signedMessage(String version, String digest) =>
    'onyx-update-macos-v1\n$version\n$digest';

/// L'empreinte du bundle [bundlePath] : le SHA-256 d'un manifeste qui donne,
/// trié par chemin, le contenu de chaque fichier et la cible de chaque lien.
///
/// Les liens ne sont jamais suivis : un framework en contient
/// (`Versions/Current -> A`), et c'est le lien lui-même qui est installé.
Future<String> bundleDigest(String bundlePath) async {
  final lines = <(List<int>, String)>[];
  await for (final entry
      in Directory(bundlePath).list(recursive: true, followLinks: false)) {
    final relative = p.posix.joinAll(p.split(p.relative(entry.path, from: bundlePath)));
    // Un saut de ligne dans un nom rendrait le manifeste ambigu.
    if (relative.contains('\n')) {
      throw const FormatException('nom de fichier invalide dans le bundle');
    }
    if (entry is Link) {
      lines.add((utf8.encode(relative), 'l $relative ${await entry.target()}\n'));
    } else if (entry is File) {
      final hash = await sha256.bind(entry.openRead()).first;
      lines.add((utf8.encode(relative), 'f $relative $hash\n'));
    }
  }
  lines.sort((a, b) => _compareBytes(a.$1, b.$1));
  return sha256.convert(utf8.encode(lines.map((l) => l.$2).join())).toString();
}

int _compareBytes(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// Dit si [signaturePath] signe le bundle [bundlePath] en [version].
///
/// La vérification passe par `/usr/bin/openssl`, présent sur tout macOS :
/// pas de cryptographie à courbe elliptique à embarquer pour une seule
/// vérification par mise à jour. [workDir] reçoit les fichiers de travail.
Future<bool> verifyBundleSignature({
  required String bundlePath,
  required String signaturePath,
  required String version,
  required String workDir,
}) async {
  if (!File(signaturePath).existsSync()) return false;
  final digest = await bundleDigest(bundlePath);
  final key = File(p.join(workDir, 'update-public-key.pem'));
  final message = File(p.join(workDir, 'update-message'));
  await key.writeAsString(updatePublicKeyPem);
  await message.writeAsString(signedMessage(version, digest));
  final result = await Process.run('/usr/bin/openssl', [
    'dgst',
    '-sha256',
    '-verify',
    key.path,
    '-signature',
    signaturePath,
    message.path,
  ]);
  return result.exitCode == 0;
}
