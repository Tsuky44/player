/// Le début d'une session HLS, téléchargé avant que le moteur ne l'ouvre —
/// voir l'implémentation io. Sans objet sur le web.
library;

export 'hls_preload_io.dart' if (dart.library.js_interop) 'hls_preload_web.dart';
