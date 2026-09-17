import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Le curseur de l'application : même allure qu'un [Slider] de Material, sans
/// son `OverlayPortal`.
///
/// `Slider` enveloppe toujours son résultat dans un `OverlayPortal`, même sans
/// indicateur de valeur. Dans une route poussée — le lecteur, le studio, une
/// fiche de demande — ce portail sème un nœud sémantique que personne ne
/// réclame comme enfant, et l'embarqueur Windows refuse alors la mise à jour
/// entière de l'arbre : `Failed to update ui::AXTree`. Le refus est définitif :
/// à partir de là chaque image réessaie et échoue, l'arbre d'accessibilité ne
/// bouge plus, et le flot d'erreurs sur la sortie d'erreur suffit à faire ramer
/// toute l'application en debug. Voir
/// https://github.com/flutter/flutter/issues/190357.
///
/// Mesuré sur un banc d'essai (Flutter 3.44.4, curseur dans une route poussée,
/// valeur changée trois fois par seconde pendant huit secondes), erreurs
/// `AXTree` produites :
///
/// | `Slider` de Material                     | 23 |
/// | `MergeSemantics` autour                  | 23 |
/// | `Semantics(...)` + `ExcludeSemantics`    | 23 |
/// | `ExcludeSemantics` seul                  |  2 |
/// | ce curseur-ci                            |  0 |
///
/// Masquer le sous-arbre laissait deux erreurs et coûtait l'annonce du contrôle
/// aux lecteurs d'écran. Ne pas créer de portail du tout n'en laisse aucune et
/// garde les sémantiques : le nœud décrit un curseur, sa valeur, et les deux
/// actions qui la changent.
///
/// L'habillage vient du [SliderTheme] ambiant, comme pour un `Slider` : les
/// appelants qui en posaient un gardent leur allure sans rien changer.
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
    this.label,
  });

  final double value;

  /// Null désactive le curseur, comme sur un `Slider`.
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;

  /// Ce qu'annonce le lecteur d'écran à la place du pourcentage.
  final String? label;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  bool _hovering = false;
  bool _dragging = false;

  /// Ce que déplacent une flèche du clavier et une action d'accessibilité.
  /// Un dixième de la course, comme Material.
  static const double _step = 0.1;

  bool get _enabled => widget.onChanged != null;

  double get _fraction {
    final span = widget.max - widget.min;
    if (span <= 0) return 0;
    return ((widget.value - widget.min) / span).clamp(0.0, 1.0);
  }

  void _emit(double fraction) {
    final handler = widget.onChanged;
    if (handler == null) return;
    final next =
        widget.min + fraction.clamp(0.0, 1.0) * (widget.max - widget.min);
    if (next != widget.value) handler(next);
  }

  /// La position d'un doigt ou d'un clic, rapportée à la piste : elle court
  /// d'un centre de pouce à l'autre, pas d'un bord à l'autre.
  void _emitFromPosition(Offset local, _SliderMetrics metrics, double width) {
    final span = metrics.trackWidthFor(width);
    if (span <= 0) return;
    _emit((local.dx - metrics.padding) / span);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowDown:
        _emit(_fraction - _step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowUp:
        _emit(_fraction + _step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _emit(0);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        _emit(1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _announce(double fraction) =>
      widget.label ?? '${(fraction * 100).round()} %';

  @override
  Widget build(BuildContext context) {
    final metrics = _SliderMetrics.of(context, enabled: _enabled);
    final fraction = _fraction;

    final interactive = LayoutBuilder(
      builder: (context, constraints) {
        // Mêmes règles de taille qu'un `Slider` : on prend la place offerte,
        // et à défaut la hauteur des pièces dessinées et la largeur minimale
        // de Material (144, soit trois cibles tactiles).
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 144 + metrics.thumbRadius * 2;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : metrics.height;
        return MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled
                ? (d) => _emitFromPosition(d.localPosition, metrics, width)
                : null,
            onHorizontalDragStart: _enabled
                ? (d) {
                    setState(() => _dragging = true);
                    _emitFromPosition(d.localPosition, metrics, width);
                  }
                : null,
            onHorizontalDragUpdate: _enabled
                ? (d) => _emitFromPosition(d.localPosition, metrics, width)
                : null,
            onHorizontalDragEnd:
                _enabled ? (_) => setState(() => _dragging = false) : null,
            onHorizontalDragCancel:
                _enabled ? () => setState(() => _dragging = false) : null,
            child: CustomPaint(
              size: Size(width, height),
              painter: _AppSliderPainter(
                fraction: fraction,
                metrics: metrics,
                // Le halo suit la souris et le glissement, comme
                // l'`overlayShape` d'un `Slider` : c'est lui qui dit que le
                // pouce est saisissable.
                halo: _enabled && (_hovering || _dragging),
              ),
            ),
          ),
        );
      },
    );

    return Semantics(
      slider: true,
      enabled: _enabled,
      value: _announce(fraction),
      increasedValue: _announce((fraction + _step).clamp(0.0, 1.0)),
      decreasedValue: _announce((fraction - _step).clamp(0.0, 1.0)),
      onIncrease: _enabled ? () => _emit(fraction + _step) : null,
      onDecrease: _enabled ? () => _emit(fraction - _step) : null,
      child: Focus(
        canRequestFocus: _enabled,
        onKeyEvent: _onKey,
        child: interactive,
      ),
    );
  }
}

/// Ce que le [SliderTheme] ambiant dit du dessin, résolu une fois.
class _SliderMetrics {
  const _SliderMetrics({
    required this.trackHeight,
    required this.thumbRadius,
    required this.haloRadius,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.haloColor,
  });

  final double trackHeight;
  final double thumbRadius;
  final double haloRadius;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final Color haloColor;

  /// La marge que le pouce garde à chaque bout, où la piste ne va pas.
  double get padding => thumbRadius;

  double get height => [trackHeight, thumbRadius * 2, haloRadius * 2]
      .reduce((a, b) => a > b ? a : b);

  double trackWidthFor(double width) => (width - padding * 2).clamp(0.0, width);

  @override
  bool operator ==(Object other) =>
      other is _SliderMetrics &&
      other.trackHeight == trackHeight &&
      other.thumbRadius == thumbRadius &&
      other.haloRadius == haloRadius &&
      other.activeColor == activeColor &&
      other.inactiveColor == inactiveColor &&
      other.thumbColor == thumbColor &&
      other.haloColor == haloColor;

  @override
  int get hashCode => Object.hash(trackHeight, thumbRadius, haloRadius,
      activeColor, inactiveColor, thumbColor, haloColor);

  static _SliderMetrics of(BuildContext context, {required bool enabled}) {
    final theme = SliderTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = (enabled
            ? theme.activeTrackColor
            : theme.disabledActiveTrackColor) ??
        scheme.primary;
    final inactive = (enabled
            ? theme.inactiveTrackColor
            : theme.disabledInactiveTrackColor) ??
        scheme.primary.withValues(alpha: 0.24);
    final thumb =
        (enabled ? theme.thumbColor : theme.disabledThumbColor) ?? active;
    final thumbShape = theme.thumbShape;
    final haloShape = theme.overlayShape;
    return _SliderMetrics(
      trackHeight: theme.trackHeight ?? 4,
      thumbRadius:
          thumbShape is RoundSliderThumbShape ? thumbShape.enabledThumbRadius : 10,
      haloRadius:
          haloShape is RoundSliderOverlayShape ? haloShape.overlayRadius : 0,
      activeColor: active,
      inactiveColor: inactive,
      thumbColor: thumb,
      haloColor: theme.overlayColor ?? active.withValues(alpha: 0.12),
    );
  }
}

class _AppSliderPainter extends CustomPainter {
  const _AppSliderPainter({
    required this.fraction,
    required this.metrics,
    required this.halo,
  });

  final double fraction;
  final _SliderMetrics metrics;
  final bool halo;

  @override
  void paint(Canvas canvas, Size size) {
    final padding = metrics.padding;
    final trackWidth = metrics.trackWidthFor(size.width);

    final centerY = size.height / 2;
    final radius = Radius.circular(metrics.trackHeight / 2);
    final track = Rect.fromLTWH(
      padding,
      centerY - metrics.trackHeight / 2,
      trackWidth,
      metrics.trackHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, radius),
      Paint()..color = metrics.inactiveColor,
    );

    final thumbX = padding + trackWidth * fraction;
    if (fraction > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(track.left, track.top, thumbX, track.bottom),
          radius,
        ),
        Paint()..color = metrics.activeColor,
      );
    }

    if (halo && metrics.haloRadius > 0) {
      canvas.drawCircle(
        Offset(thumbX, centerY),
        metrics.haloRadius,
        Paint()..color = metrics.haloColor,
      );
    }
    if (metrics.thumbRadius > 0) {
      canvas.drawCircle(
        Offset(thumbX, centerY),
        metrics.thumbRadius,
        Paint()..color = metrics.thumbColor,
      );
    }
  }

  @override
  bool shouldRepaint(_AppSliderPainter old) =>
      old.fraction != fraction || old.halo != halo || old.metrics != metrics;
}
