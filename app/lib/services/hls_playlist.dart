/// Ce qu'il faut lire d'une playlist HLS pour en télécharger le début : rien
/// de plus. Les adresses sont rendues telles qu'elles sont écrites, relatives
/// et ticket compris.
library;

/// Les deux playlists qu'un moteur ouvre d'abord.
class HlsMaster {
  const HlsMaster({this.video, this.audio});

  /// La variante vidéo : la ligne qui suit `#EXT-X-STREAM-INF`.
  final String? video;

  /// La rendition audio marquée `DEFAULT=YES`, à défaut la première. Null
  /// quand le son voyage avec l'image.
  final String? audio;
}

class HlsSegment {
  const HlsSegment(this.uri, this.duration);
  final String uri;

  /// En secondes, d'après `#EXTINF`.
  final double duration;
}

class HlsMediaPlaylist {
  const HlsMediaPlaylist({this.initUri, this.segments = const []});

  /// Le segment d'initialisation d'une session fMP4 (`#EXT-X-MAP`).
  final String? initUri;
  final List<HlsSegment> segments;
}

final _uriAttribute = RegExp(r'URI="([^"]*)"');

HlsMaster parseHlsMaster(String text) {
  String? video, audio, firstAudio;
  var expectVariant = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA') && line.contains('TYPE=AUDIO')) {
      final uri = _uriAttribute.firstMatch(line)?.group(1);
      if (uri == null || uri.isEmpty) continue;
      firstAudio ??= uri;
      if (line.contains('DEFAULT=YES')) audio ??= uri;
    } else if (line.startsWith('#EXT-X-STREAM-INF')) {
      expectVariant = true;
    } else if (expectVariant && !line.startsWith('#')) {
      video ??= line;
      expectVariant = false;
    }
  }
  return HlsMaster(video: video, audio: audio ?? firstAudio);
}

HlsMediaPlaylist parseHlsMediaPlaylist(String text) {
  String? init;
  double? duration;
  final segments = <HlsSegment>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MAP')) {
      init ??= _uriAttribute.firstMatch(line)?.group(1);
    } else if (line.startsWith('#EXTINF:')) {
      final value = line.substring('#EXTINF:'.length).split(',').first;
      duration = double.tryParse(value.trim());
    } else if (!line.startsWith('#') && duration != null) {
      segments.add(HlsSegment(line, duration));
      duration = null;
    }
  }
  return HlsMediaPlaylist(initUri: init, segments: segments);
}
