import '../../../utils/app_platform.dart';
import 'apple_playback_session.dart';
import 'avplayer_playback_session.dart';
import 'exo_playback_session.dart';
import 'mpv_playback_session.dart';
import 'playback_session.dart';

/// Construit la session pour cette plateforme.
///
/// Chaque implémentation gère le cycle de vie de son propre moteur — mpv prend
/// et rend une instance mise en commun, ExoPlayer crée et détruit la sienne.
/// Le contrôleur n'a donc rien à savoir de l'un ni de l'autre.
PlaybackSession createPlaybackSession() {
  if (AppPlatform.isAndroid) return ExoPlaybackSession();
  // Pas de libmpv pour tvOS : le lecteur du système, voir l'ADR-0028.
  if (AppPlatform.isTvOS) return AvPlayerPlaybackSession();
  // AVPlayer pour ce que le serveur recopie, mpv pour le reste : voir
  // l'ADR-0035.
  if (AppPlatform.isIOS || AppPlatform.isMacOS) return ApplePlaybackSession();
  return MpvPlaybackSession();
}
