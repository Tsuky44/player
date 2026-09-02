/// Quel moteur pilote la lecture, ici.
///
/// ExoPlayer sur Android, mpv partout ailleurs — voir l'ADR-0009. Le choix est
/// **compilé, pas testé à l'exécution** : l'implémentation mpv vit derrière un
/// import conditionnel, donc sur Android les symboles de media_kit n'existent
/// pas dans le binaire. Un `if (Platform.isAndroid)` aurait laissé le jour où
/// quelqu'un construit un lecteur mpv dans un chemin Android : ça n'aurait pas
/// cassé à la compilation, ça aurait cassé sur le téléviseur.
library;

export 'playback_engine_mpv.dart'
    if (dart.library.js_interop) 'playback_engine_mpv.dart';
