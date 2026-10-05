/// Les formats où se cache l'origine de l'installeur — voir `install_origin.dart`.
///
/// Rien que des fonctions pures : la lecture des fichiers est dans
/// `install_origin_io.dart`, ce qui se teste est ici.
library;

import 'dart:typed_data';

/// L'identifiant de la paire d'Onyx dans l'« APK Signing Block » (« ONYX »),
/// écrite par le serveur quand il sert l'APK (`server/installorigin`).
const int apkOriginBlockId = 0x4F4E5958;

/// Ce qu'il faut lire à la fin d'un ZIP pour être sûr d'y trouver son
/// enregistrement de fin : 22 octets, plus un commentaire d'au plus 65535.
const int zipTailLength = 22 + 0xFFFF;

/// Les 24 derniers octets d'un APK Signing Block : sa taille, puis sa magie.
const int apkSigningBlockFooterLength = 24;

const String _apkSigningBlockMagic = 'APK Sig Block 42';

/// Le décalage du répertoire central, lu dans la fin [tail] d'un ZIP. `null`
/// si ce n'est pas un ZIP, ou si c'est un ZIP64.
int? zipCentralDirectoryOffset(Uint8List tail) {
  final data = ByteData.sublistView(tail);
  for (var i = tail.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) != 0x06054b50) continue;
    // La signature peut apparaître par hasard dans un commentaire : le vrai
    // enregistrement est celui dont le commentaire finit avec le fichier.
    if (data.getUint16(i + 20, Endian.little) != tail.length - i - 22) continue;
    final offset = data.getUint32(i + 16, Endian.little);
    return offset == 0xFFFFFFFF ? null : offset;
  }
  return null;
}

/// La taille du bloc de signature dont [footer] est la fin (les 24 octets qui
/// précèdent le répertoire central), ou `null` si l'APK n'en a pas.
int? apkSigningBlockSize(Uint8List footer) {
  if (footer.length != apkSigningBlockFooterLength) return null;
  if (String.fromCharCodes(footer, 8) != _apkSigningBlockMagic) return null;
  final data = ByteData.sublistView(footer);
  // Les 32 bits de poids fort : un bloc de plus de 4 Go n'existe pas.
  if (data.getUint32(4, Endian.little) != 0) return null;
  final size = data.getUint32(0, Endian.little);
  return size < apkSigningBlockFooterLength ? null : size;
}

/// La valeur de la paire [id] parmi les [pairs] d'un bloc de signature :
/// une suite de `longueur (8) | identifiant (4) | valeur`.
Uint8List? apkSigningBlockValue(Uint8List pairs, int id) {
  final data = ByteData.sublistView(pairs);
  var at = 0;
  while (at + 12 <= pairs.length) {
    if (data.getUint32(at + 4, Endian.little) != 0) return null;
    final length = data.getUint32(at, Endian.little);
    final next = at + 8 + length;
    if (length < 4 || next > pairs.length) return null;
    if (data.getUint32(at + 8, Endian.little) == id) {
      return Uint8List.sublistView(pairs, at + 12, next);
    }
    at = next;
  }
  return null;
}

final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$');

/// L'identifiant d'événement porté par l'attribut `com.apple.quarantine` de
/// macOS (`0083;65a1b2c3;Safari;<UUID>`). C'est la clé sous laquelle le
/// système a noté l'adresse du téléchargement.
///
/// Validé comme un UUID et rien d'autre : il part dans une requête SQL.
String? quarantineEventId(String attribute) {
  final fields = attribute.trim().split(';');
  if (fields.length < 4) return null;
  final id = fields[3];
  return _uuid.hasMatch(id) ? id.toUpperCase() : null;
}
