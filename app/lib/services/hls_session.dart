/// Holds the result of starting an HLS transcoding session.
///
/// [masterUrl] is opened directly by media_kit/mpv, which fetches the child
/// playlists and segments itself (no local temp file, no playlist rewriting).
class HlsSession {
  final String sessionId;
  final String masterUrl;
  final double totalDuration; // full media duration in seconds
  final int startOffset; // seconds into the original media

  /// Source audio tracks published as HLS renditions, in the order the player
  /// enumerates them: position k in the player's audio track list is source
  /// track `audioMap[k]`. This is what lets a language change be an mpv track
  /// switch instead of a whole new transcoding session.
  final List<int> audioMap;

  /// Bitmap subtitle stream the server actually rendered into the video, or -1.
  /// It can differ from what was requested when the track turned out not to be
  /// burnable, so the client should trust this rather than its own request.
  final int burnedSubtitle;

  /// `copy` when the server is repackaging the picture untouched, `encode` when
  /// it is re-encoding it. Empty from a server that predates the field.
  ///
  /// Worth surfacing rather than guessing: "Direct Stream" and "why is the
  /// server's CPU at 400%" are the same question, and only the server knows.
  final String videoMode;

  /// Why a copy was refused, in the server's own words. Empty on the copy path.
  final String videoReason;

  /// Les pistes texte que la session écrit elle-même, au fil du transcodage.
  /// Voir ADR-0031.
  ///
  /// Null quand le serveur est plus ancien que ces sous-titres : il faut alors
  /// passer par l'extraction d'avant. Une liste vide, elle, dit seulement que
  /// le fichier n'a pas de piste texte.
  final List<LiveSubtitleSource>? subtitles;

  /// Ce que la session garde derrière le dernier segment demandé, en
  /// secondes ; au-delà, le serveur les a effacés et reculer demande une
  /// nouvelle session. Null : tout est gardé.
  final int? retainSeconds;

  HlsSession({
    required this.sessionId,
    required this.masterUrl,
    required this.totalDuration,
    required this.startOffset,
    this.audioMap = const [],
    this.burnedSubtitle = -1,
    this.videoMode = '',
    this.videoReason = '',
    this.subtitles,
    this.retainSeconds,
  });

  /// True when the picture is reaching the viewer untouched.
  bool get isDirectStream => videoMode == 'copy';

  factory HlsSession.fromJson(Map<String, dynamic> json) {
    return HlsSession(
      sessionId: json['session_id'] as String? ?? '',
      masterUrl: json['master_url'] as String? ?? '',
      totalDuration: (json['duration'] as num? ?? 0).toDouble(),
      startOffset: json['start_offset'] as int? ?? 0,
      audioMap: (json['audio_map'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      burnedSubtitle: (json['burned_subtitle'] as num?)?.toInt() ?? -1,
      videoMode: json['video_mode'] as String? ?? '',
      videoReason: json['video_reason'] as String? ?? '',
      retainSeconds: (json['retain_seconds'] as num?)?.toInt(),
      subtitles: (json['subtitles'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(LiveSubtitleSource.fromJson)
          .where((s) => s.typedIndex >= 0 && s.url.isNotEmpty)
          .toList(),
    );
  }
}

/// Une piste texte qu'une session HLS écrit en WebVTT, et l'adresse où elle
/// grandit. L'adresse porte déjà le ticket de lecture.
class LiveSubtitleSource {
  const LiveSubtitleSource({required this.typedIndex, required this.url});

  /// La piste dans le conteneur : le N de 0:s:N, qui est aussi
  /// `MediaSubtitleTrack.typedIndex`.
  final int typedIndex;
  final String url;

  factory LiveSubtitleSource.fromJson(Map<String, dynamic> json) =>
      LiveSubtitleSource(
        typedIndex: (json['typed_index'] as num?)?.toInt() ?? -1,
        url: json['url'] as String? ?? '',
      );
}
