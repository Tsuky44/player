/// La télécommande LG, rendue lisible par Flutter — voir `webos_remote_keys.dart`.
library;

export 'webos_remote_io.dart'
    if (dart.library.js_interop) 'webos_remote_web.dart';
