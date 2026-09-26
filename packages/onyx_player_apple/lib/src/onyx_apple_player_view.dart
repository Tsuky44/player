import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// La vue où AetherEngine pose son image.
///
/// Une vraie vue du système (`UIView` sur iPhone et Apple TV, `NSView` sur
/// Mac), pas une texture : la couche d'AVPlayer y est composée par le système
/// sous l'interface Flutter, HDR et Dolby Vision compris, sans copie d'image.
///
/// **Ce que Flutter peut lui faire.** La dimensionner et la découper : c'est
/// ainsi que se règle le cadrage, par la taille de la vue (voir l'ADR-0035).
/// Dessiner par-dessus fonctionne normalement : chrome, sous-titres et menus
/// se composent au-dessus. La vue ne prend aucun geste, pour qu'ils arrivent
/// aux détecteurs du lecteur.
class OnyxApplePlayerView extends StatelessWidget {
  const OnyxApplePlayerView({super.key, required this.playerId});

  /// Le lecteur auquel cette vue se rattache — [OnyxApplePlayer.id].
  final int playerId;

  /// Doit correspondre à `PlayerSurfaceFactory.viewType` côté Swift.
  static const String _viewType = 'onyx_player_apple/surface';
  static const String _playerIdKey = 'playerId';

  @override
  Widget build(BuildContext context) {
    final params = <String, dynamic>{_playerIdKey: playerId};
    const codec = StandardMessageCodec();
    const gestures = <Factory<OneSequenceGestureRecognizer>>{};
    // L'Apple TV se présente comme iOS à Flutter : c'est bien une UIView.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return AppKitView(
        viewType: _viewType,
        creationParams: params,
        creationParamsCodec: codec,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: gestures,
      );
    }
    return UiKitView(
      viewType: _viewType,
      creationParams: params,
      creationParamsCodec: codec,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      gestureRecognizers: gestures,
    );
  }
}
