/// Ownership of the parts of browser playback that `media_kit`'s web backend
/// gets wrong.
///
/// Two concrete defects, both unreachable from normal Dart code:
///
///  * Its `_loadSource` builds an `Hls` instance per `open()` and never calls
///    `destroy()` — the package exposes only `loadSource` and `attachMedia`, so
///    nobody else can either. This player rebuilds its HLS session on every
///    quality change, audio change and large seek, so the abandoned instances
///    pile up on the same `<video>`, each still running its own loaders and
///    error handlers. That is the stalling and endless buffering.
///
///  * Its `setSubtitleTrack` installs an `oncuechange` handler that the package
///    author annotates in-source as "UNTESTED (…) a very good chance of not
///    working". It throws on every cue and prints the exception plus a full
///    stack trace — several times a second while subtitles are on. The main
///    thread saturates, Flutter stops painting, and audio keeps going on its own
///    thread: the picture freezes while the sound continues.
///
/// So this layer keeps the text tracks and the hls.js lifetime for itself. The
/// rest — play, pause, seek, position, volume, rate — media_kit handles fine and
/// is left alone.
library;

export 'web_playback_io.dart'
    if (dart.library.js_interop) 'web_playback_web.dart';
