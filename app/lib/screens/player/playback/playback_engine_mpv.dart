import '../../../utils/app_platform.dart';
import 'aether_playback_session.dart';
import 'exo_playback_session.dart';
import 'mpv_playback_session.dart';
import 'playback_session.dart';
import 'webos_playback_session.dart';

/// Construit la session pour cette plateforme.
///
/// Chaque implémentation gère le cycle de vie de son propre moteur — mpv prend
/// et rend une instance mise en commun, ExoPlayer crée et détruit la sienne.
/// Le contrôleur n'a donc rien à savoir de l'un ni de l'autre.
PlaybackSession createPlaybackSession() {
  if (AppPlatform.isAndroid) return ExoPlaybackSession();
  // AetherEngine sur tous les appareils Apple, en Direct Play : voir
  // l'ADR-0038.
  if (AppPlatform.isApple) return AetherPlaybackSession();
  // Un téléviseur LG lit le fichier par son propre pipeline : voir
  // l'ADR-0076.
  if (AppPlatform.isWebOS) return createWebOSPlaybackSession();
  return MpvPlaybackSession();
}

/// Si le moteur d'ici ouvre le fichier lui-même (Direct Play).
///
/// Un onglet de bureau ne lit pas les conteneurs et les codecs d'une
/// médiathèque privée : le web part directement en HLS, au palier que la liste
/// de pistes indique. Tous les moteurs natifs ouvrent le fichier — AetherEngine
/// compris (ADR-0038) — et le navigateur d'un téléviseur LG aussi, dont le
/// `<video>` confie le fichier aux décodeurs du téléviseur (ADR-0076).
bool get engineOpensFiles => !AppPlatform.isWeb || AppPlatform.isWebOS;

/// Si le moteur d'ici voit les sous-titres du fichier.
///
/// Un `<video>` ne connaît que les `<track>` qu'on lui donne : dans un
/// navigateur — Direct Play d'un téléviseur LG compris — les sous-titres
/// viennent toujours des WebVTT du serveur.
bool get engineReadsEmbeddedSubtitles => !AppPlatform.isWeb;
