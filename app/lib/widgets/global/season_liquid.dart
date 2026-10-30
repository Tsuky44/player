import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Le mouvement liquide des bulles de saisons, porté d'OnyxHub
/// (`season/liquid.ts`, `lib/spring.ts`).
///
/// OnyxHub fond la goutte et les bulles avec un filtre SVG de fusion, qui
/// redessine toute la rangée à chaque image : c'est ce que les petites TV ne
/// tiennent pas (ADR-0086). Ici la goutte est un seul chemin plein, peint dans
/// un [CustomPainter] qui écoute l'horloge et rien d'autre : aucune
/// reconstruction de widget pendant le trajet, aucun calque filtré. Le mode
/// léger et « réduire les animations » la suppriment (`AppMotion.reduced`) ;
/// les bulles se gonflent alors sans ressort.

/// Lissage de 0 à 1 (smoothstep), borné.
double smooth(double x) => x <= 0 ? 0 : (x >= 1 ? 1 : x * x * (3 - 2 * x));

/// Ressort amorti : de 0 à 1, vitesse nulle au départ, léger dépassement puis
/// repos. [t] en secondes, [w] la pulsation (raideur), [z] l'amortissement
/// (< 1 : rebond).
double spring(double t, double w, double z) {
  if (t <= 0) return 0;
  final wd = w * math.sqrt(1 - z * z);
  return 1 -
      math.exp(-z * w * t) *
          (math.cos(wd * t) + (z * w / wd) * math.sin(wd * t));
}

/// Le reste d'oscillation s'éteint sur le dernier cinquième : la pose est
/// exacte.
double _land(double s, double span) =>
    1 - smooth((s - 0.8 * span) / (0.2 * span));

/// Le ressort d'une bulle qui change de largeur. [span] est la durée de
/// l'animation en secondes ; [delay] l'attente avant que la bulle ne se
/// gonfle (la goutte doit l'avoir atteinte).
class SeasonSpring extends Curve {
  const SeasonSpring._({
    required this.span,
    required this.w,
    required this.z,
    this.delay = 0,
  });

  /// La bulle choisie : elle se gonfle quand la goutte arrive, en rebondissant.
  const SeasonSpring.grow({required double span, double delay = 0})
      : this._(span: span, w: 11, z: 0.5, delay: delay);

  /// La bulle quittée : elle se retracte tout de suite, un peu plus sec.
  const SeasonSpring.shrink({required double span})
      : this._(span: span, w: 13, z: 0.62);

  final double span;
  final double w;
  final double z;
  final double delay;

  @override
  double transformInternal(double t) {
    final s = t * span;
    return 1 - (1 - spring(s - delay, w, z)) * _land(s, span);
  }
}

/// Le trajet d'une goutte d'une bulle à l'autre, fixé au moment du toucher.
class SeasonDropPlan {
  SeasonDropPlan({
    required this.origin,
    required this.target,
    required this.span,
  }) : dir = target >= origin ? 1.0 : -1.0 {
    var peak = 1e-6;
    for (var f = 0; f < _frames; f++) {
      peak = math.max(peak, speed(f * _step, target).abs());
    }
    _peak = peak;
  }

  static const _frames = 72;
  static const _tails = [(size: 20.0, lag: 0.035), (size: 13.6, lag: 0.07)];

  /// Abscisse du centre de la bulle quittée, dans la rangée.
  final double origin;

  /// Abscisse du centre de la bulle choisie à l'instant du toucher ; elle
  /// bouge pendant que la rangée se reforme, le peintre relit la vraie.
  final double target;

  /// Durée en secondes.
  final double span;
  final double dir;
  late final double _peak;

  double get _step => span / (_frames - 1);

  /// Diamètre de la goutte, en pixels.
  static const drop = 40.0;

  /// Prise d'élan : la goutte recule et se tasse avant de partir.
  double _windup(double s) =>
      s < 0.14 ? math.pow(math.sin(math.pi * s / 0.14), 2).toDouble() : 0;

  double _travel(double s, double lag) =>
      1 - (1 - spring(s - 0.05 - lag, 9, 0.74)) * _land(s, span);

  double center(double s, double toX, [double lag = 0]) =>
      origin +
      (toX - origin) * _travel(s, lag) -
      (lag == 0 ? dir * 5 * _windup(s) : 0);

  double speed(double s, double toX) =>
      (center(s + _step, toX) - center(s - _step, toX)) / 2;

  /// La goutte et ses deux gouttelettes de traîne à l'instant [s], vers [toX].
  /// Le premier ovale est la goutte.
  List<Rect> shapes(double s, double toX, double cy) {
    final v = speed(s, toX).abs() / _peak;
    final land = _land(s, span);
    final sx = 1 + (0.3 * v - 0.12 * _windup(s)) * land;
    // Naît dans la bulle quittée, se fond dans la bulle choisie.
    final k = (0.7 + 0.3 * smooth(s / 0.12)) *
        (1 - 0.25 * smooth((s - 0.7 * span) / (0.3 * span)));
    Rect oval(double cx, double w, double h) =>
        Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    return [
      oval(center(s, toX), drop * k * sx, drop * k / sx),
      for (final tail in _tails)
        oval(
          center(s, toX, tail.lag),
          tail.size * (0.6 + 0.4 * smooth(s / 0.15)),
          tail.size * (0.6 + 0.4 * smooth(s / 0.15)),
        ),
    ];
  }
}

/// Peint la goutte : un seul chemin plein, donc pas de surcharge là où les
/// formes se recouvrent. Le cou qui la retient à la bulle quittée s'amincit
/// avec la distance, comme un liquide qui s'étire.
class SeasonDropPainter extends CustomPainter {
  SeasonDropPainter({
    required this.clock,
    required this.plan,
    required this.targetX,
    required this.anchorX,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final SeasonDropPlan plan;

  /// Abscisse actuelle du centre de la bulle choisie, ou nul si elle n'est
  /// plus mesurable (la goutte vise alors la place du toucher).
  final double? Function() targetX;

  /// Abscisse actuelle du rond de la bulle quittée, où s'accroche le cou.
  final double? Function() anchorX;

  static final _paint = Paint()
    ..color = const Color(0x38FFFFFF)
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final s = clock.value * plan.span;
    if (s <= 0 || s >= plan.span) return;
    final cy = size.height / 2;
    final shapes = plan.shapes(s, targetX() ?? plan.target, cy);
    final path = Path();
    for (final oval in shapes) {
      path.addOval(oval);
    }
    final anchor = anchorX() ?? plan.origin;
    final drop = shapes.first;
    final gap = (drop.center.dx - anchor).abs();
    final neck = 20 * (1 - smooth(gap / 120));
    if (neck > 1.5) {
      final hull = _hull(anchor, neck, drop.center.dx, drop.width / 2, cy);
      if (hull != null) path.addPath(hull, Offset.zero);
    }
    canvas.drawPath(path, _paint);
  }

  /// L'enveloppe de deux cercles de même ordonnée. Orientée comme `addOval`
  /// (sens horaire à l'écran) : en remplissage non nul, deux sens opposés
  /// se creuseraient là où les formes se recouvrent.
  static Path? _hull(double x1, double r1, double x2, double r2, double y) {
    final d = (x2 - x1).abs();
    if (d <= (r1 - r2).abs()) return null;
    final a = math.acos((r1 - r2) / d);
    final base = x2 >= x1 ? 0.0 : math.pi;
    Offset on(double x, double r, double angle) =>
        Offset(x + r * math.cos(angle), y + r * math.sin(angle));
    final points = [
      on(x1, r1, base - a),
      on(x2, r2, base - a),
      on(x2, r2, base + a),
      on(x1, r1, base + a),
    ];
    var area = 0.0;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final q = points[(i + 1) % points.length];
      area += p.dx * q.dy - q.dx * p.dy;
    }
    final ordered = area >= 0 ? points : points.reversed.toList();
    return Path()..addPolygon(ordered, true);
  }

  @override
  bool shouldRepaint(SeasonDropPainter old) => old.plan != plan;
}
