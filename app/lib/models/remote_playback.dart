import 'models.dart';
import 'server_activity.dart';

/// Une lecture de ce compte sur un autre appareil, avec de quoi l'ouvrir ici.
/// Miroir de `server/handlers/playback_handoff.go`.
class RemotePlayback {
  final NowPlayingSession session;
  final HomeMediaItem media;

  const RemotePlayback({required this.session, required this.media});

  static RemotePlayback? tryParse(Map<String, dynamic> json) {
    final media = json['media'];
    if (media is! Map<String, dynamic>) return null;
    return RemotePlayback(
      session: NowPlayingSession.fromJson(json),
      media: HomeMediaItem.fromJson(media),
    );
  }
}

/// Ce lecteur a passé la main : le même titre a démarré sur [deviceName].
class PlaybackHandoff {
  final String deviceName;

  /// La lecture de l'autre appareil telle qu'elle est maintenant, quand il
  /// bat encore.
  final NowPlayingSession? playback;

  const PlaybackHandoff({required this.deviceName, this.playback});

  factory PlaybackHandoff.fromJson(Map<String, dynamic> json) {
    final playback = json['playback'];
    return PlaybackHandoff(
      deviceName: json['device_name'] as String? ?? '',
      playback: playback is Map<String, dynamic>
          ? NowPlayingSession.fromJson(playback)
          : null,
    );
  }
}
