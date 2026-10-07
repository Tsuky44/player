import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import 'onyx/onyx_chrome_theme.dart';
import 'player_chrome_fade.dart';
import '../../../l10n/tr.dart';

/// L'écran verrouillé du lecteur, sur un appareil tenu en main.
///
/// Monté seulement pendant le verrouillage, tout en haut de la pile du lecteur :
/// il prend chaque doigt posé sur l'image, si bien que ni le chrome, ni les
/// zones ±10 s, ni le pincement ne répondent. Un téléphone posé sur une
/// couette, tenu par un enfant ou glissé contre une joue ne met plus le film
/// en pause.
///
/// Sortir demande deux gestes voulus, parce qu'un seul serait exactement le
/// toucher accidentel que le verrou existe pour ignorer : un appui fait
/// apparaître le cadenas, puis il faut le garder enfoncé [holdToUnlock].
/// L'anneau qui se remplit autour dit où en est l'appui ; relâcher avant la fin
/// le vide.
class PlayerScreenLock extends StatefulWidget {
  final VoidCallback onUnlock;

  const PlayerScreenLock({super.key, required this.onUnlock});

  /// Durée de l'appui qui déverrouille. Ce n'est pas une transition mais un
  /// délai de confirmation : il est long exprès, et hors de la plage
  /// d'[AppMotion] pour cette raison.
  static const Duration holdToUnlock = Duration(seconds: 2);

  /// Temps pendant lequel le cadenas reste affiché sans qu'on y touche, avant
  /// de rendre toute l'image au film.
  static const Duration padlockLinger = Duration(seconds: 3);

  @override
  State<PlayerScreenLock> createState() => PlayerScreenLockState();
}

class PlayerScreenLockState extends State<PlayerScreenLock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: PlayerScreenLock.holdToUnlock,
    // Relâché trop tôt, l'anneau se vide vite : il ne garde pas d'avance pour
    // l'appui suivant.
    reverseDuration: AppMotion.standard,
  )..addStatusListener(_handleHoldStatus);

  Timer? _hideTimer;

  // Visible dès le verrouillage : c'est la seule confirmation que le bouton a
  // fait quelque chose, et elle montre où revenir pour en sortir.
  bool _padlockVisible = true;

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hold.dispose();
    super.dispose();
  }

  /// Fait réapparaître le cadenas. Appelé par un appui sur l'image, et par le
  /// lecteur quand le bouton Retour du système est pressé écran verrouillé.
  void reveal() {
    if (!mounted) return;
    setState(() => _padlockVisible = true);
    if (!_hold.isAnimating) _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(PlayerScreenLock.padlockLinger, () {
      if (!mounted) return;
      setState(() => _padlockVisible = false);
    });
  }

  void _startHold(PointerDownEvent _) {
    // Le cadenas ne peut pas s'effacer sous le doigt qui le tient.
    _hideTimer?.cancel();
    _hold.forward();
  }

  void _endHold(PointerEvent _) {
    if (_hold.isCompleted) return;
    _hold.reverse();
    _armHide();
  }

  void _handleHoldStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    unawaited(HapticFeedback.mediumImpact());
    widget.onUnlock();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: reveal,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            minimum: const EdgeInsets.only(bottom: 28),
            child: Center(
              child: PlayerChromeFade(
                visible: _padlockVisible,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      button: true,
                      label: tr('Écran verrouillé. Maintenir deux secondes pour '
                          'déverrouiller.'),
                      // Un lecteur d'écran n'a pas d'appui chronométré : son
                      // appui long suffit.
                      onLongPress: widget.onUnlock,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _startHold,
                        onPointerUp: _endHold,
                        onPointerCancel: _endHold,
                        child: _Padlock(progress: _hold),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ExcludeSemantics(
                      child: Text(
                        tr('Maintenez pour déverrouiller'),
                        style: TextStyle(
                          color: OnyxChromeTheme.icon,
                          fontSize: AppType.subhead,
                          fontWeight: FontWeight.w500,
                          // Pas de voile derrière : le texte doit tenir seul
                          // sur une scène claire.
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Le cadenas dans son anneau. L'anneau suit [progress] de 0 à 1, en partant
/// du haut dans le sens des aiguilles.
class _Padlock extends StatelessWidget {
  final Animation<double> progress;

  const _Padlock({required this.progress});

  static const double _size = 72;
  static const double _ringWidth = 4;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _size,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, child) => CustomPaint(
          painter: _HoldRingPainter(
            progress: progress.value,
            strokeWidth: _ringWidth,
          ),
          child: Center(
            child: Icon(
              progress.value >= 1
                  ? Icons.lock_open_rounded
                  : Icons.lock_rounded,
              size: 28,
              color: OnyxChromeTheme.iconActive,
            ),
          ),
        ),
      ),
    );
  }
}

class _HoldRingPainter extends CustomPainter {
  _HoldRingPainter({required this.progress, required this.strokeWidth});

  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = OnyxChromeTheme.progressTrack,
    );
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = OnyxChromeTheme.progressPlayed,
    );
  }

  @override
  bool shouldRepaint(_HoldRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.strokeWidth != strokeWidth;
}
