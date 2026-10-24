import 'package:onyx_player_apple/onyx_player_apple.dart';

import 'playback_session.dart';

/// Traduit la panne d'AetherEngine pour le contrôleur (ADR-0038).
///
/// Un segment que le moteur ne sait pas produire (`code -5`) n'est pas une
/// source perdue : le serveur répond, c'est la recopie en fMP4 qui n'a pas pu
/// couper le fichier. Observé sur Apple TV avec un MKV aux images clés très
/// espacées (~14 s) : le découpeur plie les segments annoncés dans la playlist,
/// AVPlayer redemande l'un d'eux et le moteur abandonne.
///
/// Rendue `source`, cette panne tombait sur « démarrage abandonné » ; rendue
/// `unsupported`, elle déclenche le repli en HLS que le serveur sait produire
/// (`_handleFailure`), et la lecture démarre.
PlaybackFailure aetherFailureOf(
  OnyxApplePlayerErrorKind kind,
  String? message,
) {
  final text = message ?? kind.name;
  return PlaybackFailure(
    switch (kind) {
      OnyxApplePlayerErrorKind.source when _isSegmentProduction(text) =>
        PlaybackFailureKind.unsupported,
      OnyxApplePlayerErrorKind.source => PlaybackFailureKind.source,
      OnyxApplePlayerErrorKind.unsupported => PlaybackFailureKind.unsupported,
      OnyxApplePlayerErrorKind.unknown => PlaybackFailureKind.unknown,
    },
    text,
  );
}

bool _isSegmentProduction(String message) =>
    message.contains('Source segment could not be produced');
