import 'playback_session.dart';

/// Inatteignable hors du navigateur — voir `webos_playback_session.dart`.
PlaybackSession createWebOSPlaybackSession() =>
    throw UnsupportedError('La session webOS ne vit que dans un navigateur');
