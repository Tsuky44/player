/// Le flux du trackpad de la Siri Remote, là où il existe.
///
/// `flutter_tvos` passe par `dart:io` : le web en reçoit une version vide, sur
/// le modèle de `app_platform.dart`.
library;

export 'siri_remote_touches_io.dart'
    if (dart.library.js_interop) 'siri_remote_touches_web.dart';
