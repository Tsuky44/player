/// Native no-ops — see `web_playback.dart`.
///
/// On desktop and mobile mpv owns the demuxer, so there is no hls.js to reclaim
/// and subtitles are real tracks inside the file.
abstract final class WebPlayback {
  static void install() {}

  static void adoptHlsSession(String masterUrl) {}

  static int releaseStaleHlsSessions() => 0;

  static int releaseAllHlsSessions() => 0;

  static bool showSubtitleVtt(
    String vtt, {
    String? language,
    String? label,
  }) =>
      false;

  static bool clearSubtitles() => false;
}
