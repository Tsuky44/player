/// La lecture d'un téléviseur LG : un `<video>` qui reçoit le fichier lui-même.
///
/// Voir `webos_playback_session_web.dart` et l'ADR-0076. Hors du navigateur,
/// le symbole existe pour que `playback_engine_mpv.dart` compile partout ; il
/// n'y est jamais appelé, `AppPlatform.isWebOS` y étant une constante fausse.
library;

export 'webos_playback_session_io.dart'
    if (dart.library.js_interop) 'webos_playback_session_web.dart';
