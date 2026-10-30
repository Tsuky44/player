import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';

/// Le faisceau d'OnyxHub (`OnyxBeam`) : une lumière qui balaie une pastille
/// « Disponible » une seule fois, puis se retire de l'arbre. Une translation
/// dans son propre calque, sans reconstruction ; rien sous « réduire les
/// animations » ni en mode léger. À poser en `Positioned.fill` dans un parent
/// qui découpe ses bords.
class StatusBeam extends StatefulWidget {
  const StatusBeam({super.key});

  @override
  State<StatusBeam> createState() => _StatusBeamState();
}

class _StatusBeamState extends State<StatusBeam>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(-1.2, 0),
    end: const Offset(3.2, 0),
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  bool _started = false;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final duration = AppMotion.move(context, AppMotion.sweep);
    if (duration == Duration.zero) {
      _done = true;
      return;
    }
    _controller.duration = duration;
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: FractionallySizedBox(
          widthFactor: 0.45,
          alignment: Alignment.centerLeft,
          child: SlideTransition(
            position: _offset,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0),
                    Colors.white.withValues(alpha: 0.14),
                    Colors.white.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La mince barre d'OnyxHub (`OnyxTrack`) qui court sous « En cours ». Elle
/// tourne sans fin : isolée dans son calque, et absente en mode léger plutôt
/// que de garder le moteur en train de dessiner (ADR-0086).
class StatusTrack extends StatelessWidget {
  const StatusTrack({super.key, this.height = 2});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return const SizedBox.shrink();
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          minHeight: height,
          color: AppColors.warning,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}
