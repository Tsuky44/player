/// Téléchargements hors ligne — voir `download_manager_io.dart`.
library;

/// `dart:io` ne s'importe pas dans un build web, et un navigateur n'a de toute
/// façon pas de dossier privé où garder un film : le web se résout vers un
/// stub qui déclare la fonctionnalité indisponible, et les boutons disparaissent
/// d'eux-mêmes.
export 'download_manager_io.dart'
    if (dart.library.js_interop) 'download_manager_web.dart';
