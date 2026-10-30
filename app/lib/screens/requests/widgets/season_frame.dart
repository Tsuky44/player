import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../../theme/app_motion.dart';

/// Le cadre de verre du panneau, et la lumière posée sur son bord haut, sous
/// la bulle ouverte. Changer de saison glisse l'ancienne liste hors du cadre
/// pendant que la nouvelle entre du côté de la bulle choisie.
class SeasonFrame extends StatelessWidget {
  final ValueListenable<double?> beamX;
  final double direction;
  final Widget child;

  const SeasonFrame({
    super.key,
    required this.beamX,
    required this.direction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(child: SeasonBeam(x: beamX)),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: AnimatedSwitcher(
                  duration: AppMotion.fade(context, AppMotion.emphasis),
                  switchInCurve: AppMotion.curve,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topCenter,
                    children: [...previous, if (current != null) current],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: Offset(0.04 * direction, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La lumière du panneau : une lueur douce et un filet clair sur le bord haut.
class SeasonBeam extends StatelessWidget {
  final ValueListenable<double?> x;

  const SeasonBeam({super.key, required this.x});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: x,
      builder: (_, value, __) {
        if (value == null) return const SizedBox.shrink();
        // S'allume à l'ouverture du panneau (`onyx-season-flare`) : le cadre,
        // et donc la lumière, naît avec la première saison ouverte.
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: AppMotion.fade(context, AppMotion.sweep),
          curve: AppMotion.curve,
          builder: (_, lit, child) => Opacity(opacity: lit, child: child),
          child: Stack(
            children: [
              Positioned(
                left: value - 160,
                top: 0,
                width: 320,
                height: 112,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 1.2,
                      colors: [
                        Colors.white.withValues(alpha: 0.13),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: value - 88,
                top: 0,
                width: 176,
                height: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.8),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
