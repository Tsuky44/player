import 'package:flutter/material.dart';

import '../../../theme/app_motion.dart';

/// Comment le chrome du lecteur apparaît et disparaît : un seul fondu,
/// [AppMotion.standard], le même dans les deux sens et pour les trois chromes.
///
/// Le chrome Onyx fondait en 200 ms ; le HUD par défaut glissait en 340 ms à
/// l'entrée et disparaissait d'un coup ; le modulaire clignotait dans les deux
/// sens. Trois physiques pour un même geste, selon une préférence. Un
/// `AnimatedOpacity` repart de la valeur affichée : toucher l'écran pendant le
/// fondu le reprend en cours de route au lieu de le rejouer.
///
/// Invisible, le chrome ne prend ni le doigt ni le focus : sans quoi la
/// télécommande parcourt une barre que personne ne voit, et le lecteur ne
/// récupère jamais ses flèches.
class PlayerChromeFade extends StatelessWidget {
  final bool visible;
  final Widget child;

  const PlayerChromeFade({
    super.key,
    required this.visible,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.fade(context),
          curve: AppMotion.curve,
          child: child,
        ),
      ),
    );
  }
}
