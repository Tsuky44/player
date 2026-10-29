import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';

/// La pastille de statut posée sur une affiche du catalogue, au code d'OnyxHub
/// (`MediaCardStatus`) : verte (disponible), demi-pastille jaune
/// (partiellement disponible), jaune qui pulse (en cours), blanche (demandé
/// mais pas encore sorti).
class RequestStatusDot extends StatelessWidget {
  final RequestMediaStatus status;
  final bool awaitingRelease;

  const RequestStatusDot({
    super.key,
    required this.status,
    this.awaitingRelease = false,
  });

  static const double size = 12;

  @override
  Widget build(BuildContext context) {
    if (status == RequestMediaStatus.unknown) return const SizedBox.shrink();
    if (awaitingRelease) {
      return _Dot(
        label: tr('En attente de sortie'),
        fill: const BoxDecoration(color: AppColors.textPrimary),
      );
    }
    return switch (status) {
      RequestMediaStatus.available => _Dot(
          label: tr('Disponible'),
          fill: const BoxDecoration(color: AppColors.success),
        ),
      RequestMediaStatus.partial => _Dot(
          label: tr('Partiellement disponible'),
          fill: const BoxDecoration(
            gradient: LinearGradient(
              // La moitié vide prend le gris des pistes, comme chez OnyxHub.
              colors: [
                AppColors.warning,
                AppColors.warning,
                AppColors.textMuted,
                AppColors.textMuted,
              ],
              stops: [0, 0.5, 0.5, 1],
            ),
          ),
        ),
      _ => _Dot(
          label: tr('En cours de traitement'),
          fill: const BoxDecoration(color: AppColors.warning),
          pulse: true,
        ),
    };
  }
}

class _Dot extends StatelessWidget {
  final String label;
  final BoxDecoration fill;
  final bool pulse;

  const _Dot({required this.label, required this.fill, this.pulse = false});

  @override
  Widget build(BuildContext context) {
    Widget dot = Container(
      width: RequestStatusDot.size,
      height: RequestStatusDot.size,
      foregroundDecoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.black.withValues(alpha: 0.5), width: 2),
      ),
      decoration: fill.copyWith(shape: BoxShape.circle),
    );
    if (pulse && !AppMotion.reduced(context)) dot = _Pulse(child: dot);
    return Tooltip(
      message: label,
      child: Semantics(label: label, child: dot),
    );
  }
}

/// La respiration d'une pastille « en cours ». Une boucle sans fin garde le
/// moteur en train de dessiner tant qu'elle est à l'écran : elle ne touche que
/// l'opacité (aucune reconstruction) et s'isole dans son propre calque, si
/// bien que chaque image ne repeint que ses 12 px. Absente en mode léger.
class _Pulse extends StatefulWidget {
  final Widget child;

  const _Pulse({required this.child});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this)
    ..repeat(reverse: true, period: AppMotion.ambient ~/ 2);

  late final Animation<double> _opacity = Tween<double>(begin: 1, end: 0.5)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: FadeTransition(opacity: _opacity, child: widget.child),
      );
}
