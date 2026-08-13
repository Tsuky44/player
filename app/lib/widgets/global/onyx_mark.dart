import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Marque Onyx : lentille, triangle play, faisceau qui se resserre vers la
/// droite.
///
/// Dessinée en [CustomPainter] à partir de la géométrie de
/// `brand/onyx-mark.svg` (grille interne 512), donc pas d'asset à embarquer ni
/// de dépendance SVG à ajouter au pubspec.
class OnyxMark extends StatelessWidget {
  /// Hauteur de la marque ; la largeur suit le ratio de la variante.
  final double size;

  /// Le faisceau se réduit à un aplat gris illisible sous ~40px de haut : on le
  /// coupe pour les usages compacts (top bar, chrome lecteur) et on ne garde
  /// que la lentille, qui reste carrée.
  final bool showBeam;

  final Color color;

  const OnyxMark({
    super.key,
    this.size = 32,
    this.showBeam = false,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * (showBeam ? _OnyxMarkPainter.beamAspect : 1),
      height: size,
      child: CustomPaint(
        painter: _OnyxMarkPainter(showBeam: showBeam, color: color),
      ),
    );
  }
}

class _OnyxMarkPainter extends CustomPainter {
  final bool showBeam;
  final Color color;

  const _OnyxMarkPainter({required this.showBeam, required this.color});

  /// Boîtes englobantes sur la grille source, liseré compris.
  static const _beamBox = Rect.fromLTRB(27, 121, 477, 391);
  static const _lensBox = Rect.fromLTRB(27, 121, 297, 391);

  static const beamAspect = 450 / 270;

  /// Intérieur de la lentille : plus sombre que le fond de l'app, pour que la
  /// marque tienne aussi sur une surface claire ou une affiche.
  static const _lensFill = Color(0xFF0E1010);

  @override
  void paint(Canvas canvas, Size size) {
    final box = showBeam ? _beamBox : _lensBox;
    canvas.save();
    canvas.scale(size.height / box.height);
    canvas.translate(-box.left, -box.top);

    if (showBeam) {
      const beamBounds = Rect.fromLTRB(202, 141, 477, 371);
      final beam = Path()
        ..moveTo(202, 141)
        ..lineTo(477, 226)
        ..lineTo(477, 286)
        ..lineTo(202, 371)
        ..close();
      canvas.drawPath(
        beam,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              color.withValues(alpha: 0.315),
              color.withValues(alpha: 0),
            ],
          ).createShader(beamBounds),
      );
    }

    const center = Offset(162, 256);
    canvas.drawCircle(center, 130, Paint()..color = _lensFill);
    canvas.drawCircle(
      center,
      130,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10,
    );
    canvas.drawPath(
      Path()
        ..moveTo(122, 191)
        ..lineTo(122, 321)
        ..lineTo(227, 256)
        ..close(),
      Paint()..color = color,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_OnyxMarkPainter old) =>
      old.showBeam != showBeam || old.color != color;
}
