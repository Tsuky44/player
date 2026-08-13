/// Audio/subtitle choices carried over when auto-advancing to the next episode.
class PlayerPlaybackPreferences {
  final int audioIndex;

  /// Language of the chosen audio track, when the previous media knew it.
  ///
  /// [audioIndex] stays the authoritative selection — it is what gets re-applied
  /// once the next episode's track list arrives. This is the same choice
  /// expressed in a form mpv can act on *before* the file is loaded, so the
  /// right track is picked at load time instead of being switched to a second
  /// later, mid-sentence.
  final String? audioLang;

  final String? subtitleLang;
  final String? internalSubId;

  /// True when the previous episode had no active subtitles.
  final bool subtitlesOff;

  const PlayerPlaybackPreferences({
    required this.audioIndex,
    this.audioLang,
    this.subtitleLang,
    this.internalSubId,
    required this.subtitlesOff,
  });
}
