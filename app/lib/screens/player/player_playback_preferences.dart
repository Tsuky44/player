/// Audio/subtitle choices carried over when auto-advancing to the next episode.
class PlayerPlaybackPreferences {
  final int audioIndex;
  final String? subtitleLang;
  final String? internalSubId;

  /// True when the previous episode had no active subtitles.
  final bool subtitlesOff;

  const PlayerPlaybackPreferences({
    required this.audioIndex,
    this.subtitleLang,
    this.internalSubId,
    required this.subtitlesOff,
  });
}
