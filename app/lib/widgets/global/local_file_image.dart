/// Image lue sur le disque — voir `local_file_image_io.dart`.
library;

/// `dart:io` ne s'importe pas dans un build web, et l'écran des
/// téléchargements — le seul appelant — n'y affiche de toute façon jamais
/// d'entrée : le stub web rend un rectangle vide.
export 'local_file_image_io.dart'
    if (dart.library.js_interop) 'local_file_image_web.dart';
