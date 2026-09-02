import '../../../utils/app_platform.dart';
import '../player_engine.dart';
import 'exo_playback_session.dart';
import 'mpv_playback_session.dart';
import 'playback_session.dart';

/// Construit la session pour cette plateforme.
///
/// [engine] est le moteur mpv mis en commun entre deux lectures. Il n'est
/// consommé que hors d'Android ; là-bas ExoPlayer possède le sien, créé et
/// détruit avec la session.
PlaybackSession createPlaybackSession(PlayerEngine engine) {
  if (AppPlatform.isAndroid) return ExoPlaybackSession();
  return MpvPlaybackSession(engine);
}
