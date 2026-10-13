/// La fenêtre de mpv glissée sous celle de l'app, sur Windows (ADR-0061).
///
/// `dart:ffi` n'existe pas dans un navigateur : le web reçoit une version qui
/// ne dessine rien et n'est jamais construite.
library;

export 'mpv_window_host_io.dart'
    if (dart.library.js_interop) 'mpv_window_host_web.dart';
