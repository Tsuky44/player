import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// Barre de progression posée sur une affiche : une gélule fine, en retrait des
/// bords.
///
/// Elle ne touche pas le bord bas. Collée là, il fallait la découper à l'arrondi
/// du coin — ses extrémités partaient en biseau et son arrondi venait doubler
/// celui de l'affiche, ce qui creusait un vide de chaque côté. Au milieu de
/// l'affiche, ses deux bouts sont des demi-cercles francs et il n'y a plus qu'un
/// seul rayon à lire.
///
/// Le placement appartient à la carte qui l'affiche ; la gélule ne connaît que
/// sa propre forme. Le retrait, lui, est celui des badges du haut — les deux
/// overlays d'une même affiche doivent s'aligner sur la même marge.
class ProgressPill extends StatelessWidget {
  const ProgressPill({super.key, required this.value});

  /// Avancement entre 0 et 1.
  final double value;

  static const double height = 4;
  static const Radius _cap = Radius.circular(height / 2);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(_cap),
        boxShadow: [
          // L'affiche derrière peut être claire : sans cette ombre courte, le
          // noir du rail s'y confond et la barre perd son contour.
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(_cap),
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
              ),
              FractionallySizedBox(
                // Un plancher, sinon un début de lecture ne remplit pas même le
                // premier demi-cercle et se lit comme une barre vide.
                widthFactor: value.clamp(0.04, 1.0),
                heightFactor: 1,
                child: const ColoredBox(color: AppColors.progress),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
