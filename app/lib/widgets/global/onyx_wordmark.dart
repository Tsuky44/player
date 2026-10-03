import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Le wordmark Onyx, tracé et non écrit.
///
/// « ONYX » composé en Manrope 800 espacé se lisait comme un gabarit : c'est la
/// police de l'interface, pas une marque. `brand/onyx-wordmark.svg` porte un
/// dessin à part — O ovale, terminaisons droites — redessiné ici en
/// [CustomPainter] pour la même raison que [OnyxMark] : ni asset, ni
/// dépendance SVG. Si la géométrie du SVG change, il faut la reporter ici.
class OnyxWordmark extends StatelessWidget {
  /// Hauteur de capitale ; la largeur suit le ratio du dessin.
  final double height;

  final Color color;

  /// Une ombre douce sous les lettres, pour le header posé sur un bandeau
  /// d'affiche : sans elle le gris clair se perd dans un ciel blanc.
  final bool shadow;

  const OnyxWordmark({
    super.key,
    this.height = 14,
    this.color = AppColors.textPrimary,
    this.shadow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Onyx',
      child: SizedBox(
        width: height * _WordmarkPainter.aspect,
        height: height,
        child: CustomPaint(
          painter: _WordmarkPainter(color: color, shadow: shadow),
        ),
      ),
    );
  }
}

class _WordmarkPainter extends CustomPainter {
  final Color color;
  final bool shadow;

  const _WordmarkPainter({required this.color, required this.shadow});

  /// Grille du SVG : 475 × 100, hauteur de capitale 100.
  static const double aspect = 475 / 100;

  static final Path _letters = _buildLetters();

  static Path _buildLetters() {
    final o = Path()
      ..addOval(const Rect.fromLTWH(0, 0, 92, 100))
      ..addOval(const Rect.fromLTWH(16, 16, 60, 68));
    Path polygon(List<double> xy) {
      final path = Path()..moveTo(xy[0], xy[1]);
      for (var i = 2; i < xy.length; i += 2) {
        path.lineTo(xy[i], xy[i + 1]);
      }
      return path..close();
    }

    // Pair-impair sur le tout : c'est ce qui évide le O, et les lettres ne se
    // chevauchent pas.
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(o, Offset.zero)
      ..addPath(
        polygon(const [
          137, 0, 153, 0, 201, 72, 201, 0, 217, 0, //
          217, 100, 201, 100, 153, 28, 153, 100, 137, 100,
        ]),
        Offset.zero,
      )
      ..addPath(
        polygon(const [
          262, 0, 280, 0, 304, 44, 328, 0, 346, 0, //
          312, 58, 312, 100, 296, 100, 296, 58,
        ]),
        Offset.zero,
      )
      ..addPath(
        polygon(const [
          391, 0, 411, 0, 433, 34, 455, 0, 475, 0, 443, 50, //
          475, 100, 455, 100, 433, 66, 411, 100, 391, 100, 423, 50,
        ]),
        Offset.zero,
      );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.height / 100);
    if (shadow) {
      canvas.drawPath(
        _letters.shift(const Offset(0, 4)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }
    canvas.drawPath(_letters, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WordmarkPainter old) =>
      old.color != color || old.shadow != shadow;
}
