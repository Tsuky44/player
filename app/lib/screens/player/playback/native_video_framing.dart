import 'package:flutter/widgets.dart';

/// Cadre une vue native par sa taille, sans transformation.
///
/// FittedBox met une texture à l'échelle ; une vue native, elle, ne suit une
/// mise à l'échelle que de façon inégale selon la plateforme (c'est aussi
/// pourquoi mpv reçoit son cadrage en options sur macOS). La vue reçoit donc
/// directement la taille que [fit] lui donne, centrée, et la couche vidéo, qui
/// garde le rapport de l'image, la remplit exactement. Voir l'ADR-0035.
///
/// AetherEngine ne s'en sert plus pour sa vue, que sa couche cadre elle-même
/// (`AetherVideoFit`), mais encore pour ce qui se peint par-dessus l'image.
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

  /// La taille de l'image entière une fois cadrée dans [box], y compris ce
  /// qui en dépasse.
  ///
  /// Pas `applyBoxFit` : pour un cadrage qui rogne, sa destination est [box]
  /// elle-même et le rognage est dit dans sa source. La vue recevait donc la
  /// taille de l'écran, l'image y tenait entière, et « Adaptatif » ne changeait
  /// rien sur aucun appareil Apple.
  static Size framedSize(BoxFit fit, double aspectRatio, Size box) {
    if (box.isEmpty || aspectRatio <= 0) return box;
    final fitsWidth = box.width / aspectRatio;
    final height = switch (fit) {
      BoxFit.fill => null,
      BoxFit.cover => fitsWidth > box.height ? fitsWidth : box.height,
      BoxFit.fitHeight => box.height,
      BoxFit.fitWidth => fitsWidth,
      BoxFit.contain ||
      BoxFit.scaleDown ||
      BoxFit.none =>
        fitsWidth < box.height ? fitsWidth : box.height,
    };
    return height == null ? box : Size(height * aspectRatio, height);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final size = framedSize(fit, aspectRatio, box);
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
