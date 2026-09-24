import '../../../models/models.dart';
import '../../../services/playback_capabilities.dart';

/// Quand AVPlayer lit à la place de mpv, sur iPhone et Mac — voir l'ADR-0035.
///
/// AVPlayer passe par le pipeline vidéo d'Apple (décodeur matériel, image
/// posée telle quelle dans la couche d'affichage) et chauffe bien moins que
/// mpv. Mais il n'ouvre pas le MKV : il ne lit un fichier que si le serveur peut
/// le **recopier** dans des segments HLS, sans toucher à l'image. Un fichier qui
/// demanderait un ré-encodage reste sur mpv en Direct Play : le serveur ne doit
/// jamais travailler pour économiser la batterie du client.
///
/// L'audio ne compte pas ici. Ce qu'AVPlayer ne décode pas (TrueHD, DTS) est
/// converti par le serveur en E-AC-3, ce qui coûte quelques pourcents d'un cœur
/// — rien à côté d'une image.
abstract final class AvPlayerRemux {
  /// Pourquoi AVPlayer ne peut pas prendre ce fichier en recopie, ou null
  /// quand il le peut.
  ///
  /// [subtitleLang] est la piste de sous-titres choisie à l'ouverture : une
  /// piste image (PGS, VobSub) n'existe en HLS qu'incrustée dans l'image, donc
  /// ré-encodée.
  static String? refusal(
    MediaTracks tracks, {
    String? subtitleLang,
    PlaybackCapabilities caps = PlaybackCapabilities.avPlayer,
  }) {
    final video = tracks.video;
    if (video == null) return 'aucune piste vidéo connue';
    final codec = _canonicalVideoCodec(video.codec);
    if (!caps.videoCodecs.contains(codec)) return 'vidéo ${video.codec}';
    if (video.bitDepth > caps.maxVideoBitDepth) {
      return 'vidéo ${video.bitDepth} bits';
    }
    if (video.hdrFormat == 'dolbyvision' && !caps.dolbyVision) {
      return 'Dolby Vision';
    }
    if (subtitleLang != null && subtitleLang.isNotEmpty) {
      for (final track in tracks.subtitles) {
        if (track.lang == subtitleLang && track.image) {
          return 'sous-titres image, à incruster';
        }
      }
    }
    return null;
  }

  /// Le nom que le serveur compare, depuis ce que ffprobe écrit.
  static String _canonicalVideoCodec(String codec) =>
      switch (codec.toLowerCase().trim()) {
        'avc' || 'avc1' || 'h264' => 'h264',
        'h265' || 'hev1' || 'hvc1' || 'hevc' => 'hevc',
        final other => other,
      };
}
