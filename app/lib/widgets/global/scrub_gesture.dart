import 'package:flutter/widgets.dart';

/// Le geste d'une barre de lecture : la barre suit le doigt, le lecteur ne
/// cherche qu'au relâchement.
///
/// Les barres du Player Studio (barre seule, timelines pilule et verre)
/// émettaient un seek à chaque pixel du glissé et se peignaient d'après la
/// position que le décodeur rapportait : la tête de lecture traînait derrière
/// le doigt de toute la latence de mpv ou du HLS, et chaque seek intermédiaire
/// coûtait une requête. La timeline pilule mettait en plus le lecteur en pause
/// au début du glissé et le relançait à la fin — un aller-retour par
/// micro-glissé. C'est le patron d'`OnyxProgressBar`, généralisé
/// (design-plans/audit-fluidite.md, finding 3).
///
/// Les pistes peintes sous ce geste lisent la position du doigt avec
/// [ScrubFractionBuilder].
class ScrubGesture extends StatefulWidget {
  /// Le seek, appelé une fois : au relâchement du glissé, ou à la fin du tap.
  final ValueChanged<double> onSeekFraction;

  /// Vrai pendant le glissé, pour qu'un appelant tienne le chrome ouvert.
  final ValueChanged<bool>? onScrubbingChanged;

  final Widget child;

  const ScrubGesture({
    super.key,
    required this.onSeekFraction,
    required this.child,
    this.onScrubbingChanged,
  });

  @override
  State<ScrubGesture> createState() => _ScrubGestureState();
}

class _ScrubGestureState extends State<ScrubGesture> {
  double? _fraction;
  bool _dragging = false;

  double? _fractionAt(Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) return null;
    return (localPosition.dx / box.size.width).clamp(0.0, 1.0);
  }

  void _show(Offset localPosition) {
    final fraction = _fractionAt(localPosition);
    if (fraction == null || fraction == _fraction) return;
    setState(() => _fraction = fraction);
  }

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    _dragging = dragging;
    widget.onScrubbingChanged?.call(dragging);
  }

  void _commit() {
    final fraction = _fraction;
    _setDragging(false);
    if (fraction != null) widget.onSeekFraction(fraction);
    // La fraction reste peinte jusqu'à la prochaine image : la position du
    // lecteur, mise à jour par le seek, prend le relais sans retour en
    // arrière visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_dragging) setState(() => _fraction = null);
    });
  }

  void _cancel() {
    _setDragging(false);
    if (_fraction != null) setState(() => _fraction = null);
  }

  @override
  void dispose() {
    // Un chrome qui disparaît en plein glissé ne doit pas rester tenu ouvert.
    if (_dragging) widget.onScrubbingChanged?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _show(d.localPosition),
      onTapUp: (_) => _commit(),
      // Le tap perd l'arène quand le doigt se met à glisser : le glissé prend
      // alors le relais. Perdue pour autre chose (un défilement vertical), la
      // fraction montrée au toucher s'efface.
      onTapCancel: () {
        if (!_dragging) _cancel();
      },
      onHorizontalDragStart: (d) {
        _setDragging(true);
        _show(d.localPosition);
      },
      onHorizontalDragUpdate: (d) => _show(d.localPosition),
      onHorizontalDragEnd: (_) => _commit(),
      onHorizontalDragCancel: _cancel,
      child: _ScrubFraction(fraction: _fraction, child: widget.child),
    );
  }
}

class _ScrubFraction extends InheritedWidget {
  final double? fraction;

  const _ScrubFraction({required this.fraction, required super.child});

  @override
  bool updateShouldNotify(_ScrubFraction old) => old.fraction != fraction;
}

/// Peint une piste à la position du doigt pendant un [ScrubGesture], et à
/// [progress] le reste du temps.
class ScrubFractionBuilder extends StatelessWidget {
  final double progress;
  final Widget Function(BuildContext context, double fraction) builder;

  const ScrubFractionBuilder({
    super.key,
    required this.progress,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final scrub = context.dependOnInheritedWidgetOfExactType<_ScrubFraction>();
    final fraction = (scrub?.fraction ?? progress).clamp(0.0, 1.0);
    return builder(context, fraction);
  }
}
