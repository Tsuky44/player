import 'package:flutter/widgets.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

import 'native_video_framing.dart';

/// Ramène un cadrage Flutter à ce que la couche vidéo d'Apple sait faire :
/// l'image entière, ou sa vue remplie. Voir [NativeVideoFraming.crops].
abstract final class AetherVideoFit {
  const AetherVideoFit._();

  static OnyxAppleVideoFit resolve(BoxFit fit, double aspectRatio, Size box) =>
      NativeVideoFraming.crops(fit, aspectRatio, box)
          ? OnyxAppleVideoFit.cover
          : OnyxAppleVideoFit.contain;
}
