import 'package:flutter/widgets.dart';

/// Cadre une vue native par sa taille, sans transformation.
///
/// FittedBox met une texture à l'échelle ; une vue native, elle, ne suit une
/// mise à l'échelle que de façon inégale selon la plateforme (c'est aussi
/// pourquoi mpv reçoit son cadrage en options sur macOS). La vue reçoit donc
/// directement la taille que [fit] lui donne, centrée, et la couche vidéo, qui
/// garde le rapport de l'image, la remplit exactement. Voir l'ADR-0035.
///
/// Tout ce qui se place en fractions de l'image (les sous-titres PGS) va dans
/// [child] : il suit alors le cadrage sans calcul de plus.
class NativeVideoFraming extends StatelessWidget {
  const NativeVideoFraming({
    super.key,
    required this.fit,
    required this.aspectRatio,
    required this.child,
  });

  final BoxFit fit;
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final size = applyBoxFit(fit, Size(aspectRatio, 1), box).destination;
        return ClipRect(
          // Les minimums aussi : sans eux, OverflowBox garde ceux, serrés, de
          // l'écran, plus grands que la hauteur d'une image en 2.39:1, et la
          // vue native ne se dessinait pas (écran noir, son présent).
          child: OverflowBox(
            minWidth: size.width,
            minHeight: size.height,
            maxWidth: size.width,
            maxHeight: size.height,
            child: SizedBox.fromSize(size: size, child: child),
          ),
        );
      },
    );
  }
}
