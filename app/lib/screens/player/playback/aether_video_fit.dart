import 'package:flutter/widgets.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

import 'native_video_framing.dart';

/// Ramène un cadrage Flutter à ce que la couche vidéo d'Apple sait faire.
///
/// La couche n'a que deux gestes qui gardent le rapport de l'image : la
/// montrer entière, ou remplir sa vue. Tout [BoxFit] se réduit à l'un des deux
/// dès qu'on sait si l'image, cadrée ainsi, dépasse de [box] : `fitHeight` sur
/// un film plus large que l'écran remplit, sur un 4:3 il laisse des bandes.
abstract final class AetherVideoFit {
  const AetherVideoFit._();

  /// En dessous, un dépassement n'est qu'un arrondi de mise en page.
  static const double _tolerance = 0.5;

  static OnyxAppleVideoFit resolve(BoxFit fit, double aspectRatio, Size box) {
    if (box.isEmpty || aspectRatio <= 0) return OnyxAppleVideoFit.contain;
    final framed = NativeVideoFraming.framedSize(fit, aspectRatio, box);
    final overflows = framed.width > box.width + _tolerance ||
        framed.height > box.height + _tolerance;
    return overflows ? OnyxAppleVideoFit.cover : OnyxAppleVideoFit.contain;
  }
}
