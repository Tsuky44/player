import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// La surface où ExoPlayer dessine.
///
/// C'est une `SurfaceView` native, pas une texture — c'est tout l'intérêt : le
/// décodeur écrit dedans et le plan vidéo de l'écran la compose, sans passer
/// par le GPU ni par la scène Flutter.
///
/// **Ce que Flutter ne peut pas lui faire.** Une SurfaceView est une couche du
/// système. La mettre à l'échelle, l'arrondir, lui donner une ombre ou la faire
/// tourner n'a aucun effet : ces transformations s'appliqueraient à un trou
/// dans la scène, pas à l'image. Tout ce qui doit changer la forme de la vidéo
/// passe donc par le natif — un redimensionnement de la vue elle-même — et pas
/// par un widget parent.
///
/// Dessiner *par-dessus* fonctionne normalement : le chrome, les sous-titres et
/// les menus se composent au-dessus sans rien de particulier.
class OnyxPlayerView extends StatelessWidget {
  const OnyxPlayerView({super.key, required this.playerId});

  /// Le lecteur auquel cette surface se rattache — [OnyxPlayer.id].
  final int playerId;

  /// Doit correspondre à `PlayerSurfaceFactory.VIEW_TYPE` côté Kotlin.
  static const String _viewType = 'onyx_player_android/surface';
  static const String _playerIdKey = 'playerId';

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: _viewType,
      creationParams: <String, dynamic>{_playerIdKey: playerId},
      creationParamsCodec: const StandardMessageCodec(),
      // La vidéo ne prend aucun geste : le lecteur pose ses propres
      // détecteurs par-dessus, et les lui faire traverser la platform view
      // ferait disparaître les taps sur les commandes.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }
}
