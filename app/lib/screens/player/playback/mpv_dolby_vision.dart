import 'package:flutter/widgets.dart';

import '../../../utils/app_platform.dart';
import '../player_engine.dart';

/// La sortie Dolby Vision d'une session mpv sous Windows (ADR-0061).
///
/// La texture de media_kit passe par l'ancien moteur de rendu de mpv, qui
/// ignore la couche RPU : un profil 5 y sort rose et vert. Seul `gpu-next`
/// l'applique, et sous Windows il ne dessine que dans une fenêtre. Cette
/// classe porte la bascule de l'une à l'autre, pour un seul média.
class MpvDolbyVisionOutput {
  MpvDolbyVisionOutput(this._engine);

  final PlayerEngine _engine;
  final ValueNotifier<bool> _active = ValueNotifier<bool>(false);

  /// Si mpv dessine dans sa propre fenêtre, sous celle de l'app.
  bool get active => _active.value;

  /// Passe la session sur la fenêtre `gpu-next`. Sans effet hors de Windows,
  /// où mpv n'a pas d'autre surface que celle qu'il a déjà.
  void enable() {
    if (!AppPlatform.isWindows || _active.value) return;
    debugPrint('mpv: Dolby Vision profil 5 — sortie gpu-next en fenêtre');
    _engine.reusable = false;
    // La surface fait le reste : c'est elle qui ouvre la fenêtre de mpv, et
    // qui la referme en disparaissant.
    _active.value = true;
  }

  /// La surface de la session : [texture], ou [window] une fois [enable]
  /// appelé.
  Widget surface({required Widget texture, required WidgetBuilder window}) {
    if (!AppPlatform.isWindows) return texture;
    return ValueListenableBuilder<bool>(
      valueListenable: _active,
      builder: (context, active, _) => active ? window(context) : texture,
    );
  }

  /// Dit dans le log si le Dolby Vision est réellement appliqué.
  ///
  /// Trois questions, trois réponses de mpv : le fichier en porte-t-il (profil
  /// et niveau de la piste), la couche RPU est-elle appliquée à l'image (mpv
  /// passe alors sa matrice en `dolbyvision`), et l'écran est-il piloté en HDR
  /// (la courbe de sortie de gpu-next).
  static Future<void> log(Future<String?> Function(String name) property) async {
    Future<String?> read(String name) async {
      final value = await property(name);
      return (value == null || value.isEmpty) ? null : value;
    }

    final profile = await read('current-tracks/video/dolby-vision-profile');
    final level = await read('current-tracks/video/dolby-vision-level');
    final matrix = await read('video-params/colormatrix');
    final source = '${await read('video-params/gamma')}/'
        '${await read('video-params/primaries')}';
    final target = '${await read('video-target-params/gamma')}/'
        '${await read('video-target-params/primaries')}';
    final peak = await read('video-target-params/max-luma');

    final dolbyVision = profile == null
        ? 'aucun (le fichier n\'en porte pas)'
        : 'profil $profile niveau ${level ?? '?'} · RPU '
            '${matrix == 'dolbyvision' ? 'appliqué' : 'NON appliqué (matrice $matrix)'}';
    debugPrint('Dolby Vision: $dolbyVision · source $source → écran $target'
        '${peak != null ? ' ($peak nits)' : ''}');
  }
}
