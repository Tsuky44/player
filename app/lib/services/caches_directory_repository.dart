/// Le dépôt de l'index du cache d'images propre à l'Apple TV — voir
/// l'implémentation io. Sans objet sur le web, où le navigateur garde les
/// images lui-même.
library;

export 'caches_directory_repository_io.dart'
    if (dart.library.js_interop) 'caches_directory_repository_web.dart';
