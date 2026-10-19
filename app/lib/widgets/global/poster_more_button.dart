import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_motion.dart';

/// « ⋯ » en haut à droite d'une vignette : les actions « Marquer comme vu » et
/// « Retirer » n'existaient qu'au clic droit et à l'appui long, deux gestes
/// que rien n'annonçait — un film abandonné restait alors en tête de l'accueil.
///
/// Partagé par la carte « Reprendre » et son aperçu agrandi, qui la recouvre :
/// le menu doit rester à portée une fois l'aperçu ouvert.
class PosterMoreButton extends StatelessWidget {
  const PosterMoreButton({
    super.key,
    this.visible = true,
    required this.onPressed,
  });

  final bool visible;

  /// Reçoit le contexte du bouton, pour ouvrir le menu sous son coin.
  final void Function(BuildContext buttonContext) onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: AppMotion.fade(context, AppMotion.micro),
      curve: AppMotion.curve,
      child: Builder(
        builder: (buttonContext) => IconButton(
          tooltip: tr('Plus d’actions'),
          onPressed: () => onPressed(buttonContext),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: 0.55),
            foregroundColor: AppColors.textPrimary,
            minimumSize: const Size(32, 32),
            fixedSize: const Size(32, 32),
            padding: EdgeInsets.zero,
          ),
          icon: const Icon(AppIcons.more, size: 20),
        ),
      ),
    );
  }

  /// Le coin bas droit du bouton, à l'écran : là où son menu s'ouvre.
  static Offset? menuAnchor(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(box.size.bottomRight(Offset.zero));
  }
}
