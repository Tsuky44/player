import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// La surface où ExoPlayer dessine.
///
/// C'est une `SurfaceView` native, pas une texture — c'est tout l'intérêt : le
/// décodeur écrit dedans et le plan vidéo de l'écran la compose, sans passer
/// par le GPU ni par la scène Flutter.
///
/// **Pourquoi ce n'est pas un simple [AndroidView].** Ce widget appelle
/// `PlatformViewsService.initAndroidView`, qui compose en *Texture Layer* : la
/// vue Android est rendue dans une texture Flutter. Une `SurfaceView` dessine
/// sur sa propre couche système et n'est pas capturable par ce chemin — au
/// mieux un rectangle noir, au pire une mesure de la composition GPU qu'on
/// cherche justement à supprimer. `initExpensiveAndroidView` force la
/// composition hybride : la vue vit dans la hiérarchie Android, et Flutter
/// dessine son interface au-dessus.
///
/// Le nom « expensive » vise les appareils sous Android 9 ; ici c'est le seul
/// mode qui donne le plan vidéo, donc le moins cher des deux.
///
/// **Ce que Flutter ne peut pas lui faire.** Une SurfaceView est une couche du
/// système. La mettre à l'échelle, l'arrondir, lui donner une ombre ou la faire
/// tourner n'a aucun effet : ces transformations s'appliqueraient à un trou
/// dans la scène, pas à l'image. Tout ce qui doit changer la forme de la vidéo
/// passe par le natif — un redimensionnement de la vue elle-même. Dessiner
/// *par-dessus* fonctionne normalement : chrome, sous-titres et menus se
/// composent au-dessus sans rien de particulier.
class OnyxPlayerView extends StatelessWidget {
  const OnyxPlayerView({super.key, required this.playerId});

  /// Le lecteur auquel cette surface se rattache — [OnyxPlayer.id].
  final int playerId;

  /// Doit correspondre à `PlayerSurfaceFactory.VIEW_TYPE` côté Kotlin.
  static const String _viewType = 'onyx_player_android/surface';
  static const String _playerIdKey = 'playerId';

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          // La vidéo ne prend aucun geste : le lecteur pose ses propres
          // détecteurs par-dessus, et absorber les taps ici rendrait chaque
          // commande du chrome inerte.
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, dynamic>{_playerIdKey: playerId},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }
}
