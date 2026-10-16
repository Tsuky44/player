import 'package:flutter/widgets.dart';

/// Cadre une vue native par sa taille, sans transformation.
///
/// FittedBox met une texture à l'échelle ; une vue native, elle, ne suit une
/// mise à l'échelle que de façon inégale selon la plateforme (c'est aussi
/// pourquoi mpv reçoit son cadrage en options sur macOS). La vue reçoit donc
/// directement la taille et la place que [frameRect] lui donne, et la couche
/// vidéo, qui garde le rapport de l'image, la remplit exactement. Voir
/// l'ADR-0035.
///
/// AetherEngine ne s'en sert pour sa vue que quand l'image a des bandes
/// incrustées : sa couche, qui cadre elle-même (`AetherVideoFit`), ne sait
/// pas les retirer. Elle s'en sert toujours pour ce qui se peint par-dessus
/// l'image.
///
/// Tout ce qui se place en fractions de l'image (les sous-titres PGS) va dans
/// [child] : il suit alors le cadrage sans calcul de plus.
class NativeVideoFraming extends StatelessWidget {
  const NativeVideoFraming({
    super.key,
    required this.fit,
    required this.aspectRatio,
    this.activeArea,
    required this.child,
  });

  final BoxFit fit;
  final double aspectRatio;

  /// La part du cadre qui est l'image, en fractions ; null pour le cadre
  /// entier. Voir [frameRect].
  final Rect? activeArea;
  final Widget child;

  /// Le cadre entier, en fractions de lui-même.
  static const Rect wholeFrame = Rect.fromLTWH(0, 0, 1, 1);

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

  /// Où poser le cadre entier, dans [box], pour que [fit] s'applique à
  /// [activeArea] et non au cadre.
  ///
  /// Un film 2.39 encodé en 16:9 porte ses bandes dans ses pixels. Cadrer le
  /// fichier entier les gardait, quel que soit le zoom : c'est la zone utile
  /// qui est cadrée, centrée, et le cadre entier suit autour d'elle — ses
  /// bandes incrustées sortent alors de l'écran avec ce qui est rogné. Le
  /// rapport de l'image ne change jamais : la zone utile garde le sien, et le
  /// cadre le sien. Voir ADR-0067.
  static Rect frameRect(
    BoxFit fit,
    double aspectRatio,
    Size box, {
    Rect? activeArea,
  }) {
    if (box.isEmpty || aspectRatio <= 0) return Offset.zero & box;
    final area = usableArea(activeArea) ?? wholeFrame;
    final contentAspect = aspectRatio * area.width / area.height;
    final content = framedSize(fit, contentAspect, box);
    final frame = Size(content.width / area.width, content.height / area.height);
    final contentLeft = (box.width - content.width) / 2;
    final contentTop = (box.height - content.height) / 2;
    return Rect.fromLTWH(
      contentLeft - area.left * frame.width,
      contentTop - area.top * frame.height,
      frame.width,
      frame.height,
    );
  }

  /// [area] s'il décrit vraiment une part du cadre, null sinon : un serveur
  /// ne doit pas pouvoir faire disparaître l'image par une mesure absurde.
  static Rect? usableArea(Rect? area) {
    if (area == null) return null;
    final inside = area.left >= 0 &&
        area.top >= 0 &&
        area.right <= 1.0001 &&
        area.bottom <= 1.0001;
    if (!inside || area.width < 0.2 || area.height < 0.2) return null;
    return area == wholeFrame ? null : area;
  }

  /// En dessous, un dépassement n'est qu'un arrondi de mise en page.
  static const double _cropTolerance = 0.5;

  /// Si l'image, cadrée par [fit] dans [box], en sort — c'est-à-dire si le
  /// cadrage rogne.
  ///
  /// Les couches vidéo qui cadrent elles-mêmes (AetherEngine) n'ont que deux
  /// gestes qui gardent le rapport : l'image entière, ou la vue remplie. Tout
  /// [BoxFit] s'y ramène par cette question : « Remplir la hauteur » d'un film
  /// plus large que l'écran le remplit, d'un 4:3 il laisse les côtés.
  static bool crops(BoxFit fit, double aspectRatio, Size box) {
    if (box.isEmpty || aspectRatio <= 0) return false;
    final framed = framedSize(fit, aspectRatio, box);
    return framed.width > box.width + _cropTolerance ||
        framed.height > box.height + _cropTolerance;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final rect = frameRect(fit, aspectRatio, box, activeArea: activeArea);
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Positionné plutôt que centré dans un OverflowBox : la zone
              // utile n'est pas toujours au milieu du cadre, et le cadre doit
              // alors être décalé pour qu'elle le soit à l'écran. Ses deux
              // dimensions sont fixées, ce qui donne aussi à la vue native des
              // minimums à sa taille — sans eux, elle ne se dessinait pas dans
              // un cadre plus haut que l'écran (écran noir, son présent).
              Positioned.fromRect(rect: rect, child: child),
            ],
          ),
        );
      },
    );
  }
}
