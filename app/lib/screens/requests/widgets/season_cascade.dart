import 'package:flutter/widgets.dart';

import '../../../theme/app_motion.dart';

/// L'arrivée en cascade du panneau d'une saison, comme OnyxHub
/// (`onyx-season-cascade`) : l'en-tête puis chaque épisode montent de
/// quelques pixels en apparaissant, [AppMotion.stagger] après le précédent.
///
/// Pensée pour tenir sur une petite TV, comme `StaggeredEntranceScope` :
/// **une seule horloge** pour tout le panneau, **seuls les [maxAnimated]
/// premiers** jouent, **ni échelle ni flou**, et un enfant arrivé est rendu
/// tel quel, sans calque d'opacité. Sous « réduire les animations » et en mode
/// léger l'horloge ne dure pas : tout est posé d'emblée.
class SeasonCascade {
  SeasonCascade(TickerProvider vsync)
      : clock = AnimationController(vsync: vsync);

  static const maxAnimated = 8;

  /// Combien l'enfant monte en arrivant.
  static const rise = 14.0;

  final AnimationController clock;

  static Duration total(BuildContext context) => AppMotion.move(
        context,
        AppMotion.emphasis + AppMotion.stagger * (maxAnimated - 1),
      );

  /// Rejoue la cascade depuis le début.
  void play(BuildContext context) {
    clock.duration = total(context);
    if (clock.duration == Duration.zero) {
      clock.value = 1;
      return;
    }
    clock.forward(from: 0);
  }

  void dispose() => clock.dispose();

  /// Enveloppe l'enfant de rang [index] (0 pour l'en-tête).
  Widget item(int index, Widget child) =>
      _Rise(clock: clock, index: index, child: child);
}

class _Rise extends AnimatedWidget {
  const _Rise({
    required Animation<double> clock,
    required this.index,
    required this.child,
  }) : super(listenable: clock);

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clock = listenable as AnimationController;
    final total = clock.duration;
    if (total == null || total == Duration.zero || clock.value >= 1) {
      return child;
    }
    final rank = index < SeasonCascade.maxAnimated
        ? index
        : SeasonCascade.maxAnimated - 1;
    final begin =
        (AppMotion.stagger * rank).inMicroseconds / total.inMicroseconds;
    final end =
        begin + AppMotion.emphasis.inMicroseconds / total.inMicroseconds;
    final t = Interval(begin, end.clamp(0.0, 1.0), curve: Curves.easeOutCubic)
        .transform(clock.value);
    if (t >= 1) return child;
    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, SeasonCascade.rise * (1 - t)),
        child: child,
      ),
    );
  }
}
