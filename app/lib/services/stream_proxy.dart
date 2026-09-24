/// Le relais local par lequel mpv ouvre ses flux HTTPS — voir
/// l'implémentation io. Sans objet sur le web.
library;

export 'stream_proxy_io.dart' if (dart.library.js_interop) 'stream_proxy_web.dart';
