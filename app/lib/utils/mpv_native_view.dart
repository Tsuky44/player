/// Sur macOS, mpv dessine lui-même dans une vue native au lieu de la texture
/// de media_kit — c'est ce qui donne accès à `gpu-next`, donc au Dolby Vision.
/// Voir l'ADR-0015.
///
/// Actif dès qu'un libmpv patché se charge : celui que
/// `packages/onyx_mpv_macos/native/build_libmpv.sh` installe, ou un autre
/// désigné au lancement (`--dart-define=ONYX_LIBMPV=…`). Sans lui, la texture
/// de media_kit reste en place.
///
/// `dart:ffi` et `dart:io` n'existent pas dans un navigateur : le web reçoit
/// une version où le mode n'est jamais actif.
library;

export 'mpv_native_view_io.dart'
    if (dart.library.js_interop) 'mpv_native_view_web.dart';
