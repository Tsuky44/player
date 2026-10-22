import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Côté de la photo envoyée : de quoi rester nette sur l'écran du salon, sans
/// envoyer au serveur les douze mégapixels d'un téléphone.
const avatarPhotoSide = 384;

/// Recadre [source] au carré, par le centre, la réduit à [avatarPhotoSide] et
/// la rend en PNG. Lève une [FormatException] quand ce n'est pas une image.
///
/// Fait ici plutôt que sur le serveur : il n'a pas de quoi redimensionner
/// sans dépendance (ADR-0078), et l'envoi est d'autant plus court.
Future<Uint8List> squareAvatarPng(Uint8List source) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(source);
  } catch (_) {
    throw const FormatException('not an image');
  }
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final side = image.width < image.height ? image.width : image.height;
    final crop = ui.Rect.fromLTWH(
      (image.width - side) / 2,
      (image.height - side) / 2,
      side.toDouble(),
      side.toDouble(),
    );
    final target = side < avatarPhotoSide ? side : avatarPhotoSide;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      crop,
      ui.Rect.fromLTWH(0, 0, target.toDouble(), target.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final squared = await recorder.endRecording().toImage(target, target);
    try {
      final bytes = await squared.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw const FormatException('cannot encode');
      return bytes.buffer.asUint8List();
    } finally {
      squared.dispose();
    }
  } finally {
    image.dispose();
    codec.dispose();
  }
}
