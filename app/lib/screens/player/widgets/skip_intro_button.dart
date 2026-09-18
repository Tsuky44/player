import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../hooks/use_episode_navigation.dart';

/// The "skip intro" offer.
///
/// When the automatic skip is on it also shows what is about to happen: a bar
/// fills across the button for the few seconds it is left alone, and the
/// seconds left are written next to the label. Touching anything freezes it —
/// the countdown disappears and the plain button stays, still there to press.
///
/// The countdown here is a display only. The controller owns the timer and
/// performs the skip, so the intro is skipped once even when the button is
/// hidden behind a Studio layout or a fixed chrome.
class SkipIntroButton extends StatefulWidget {
  final VoidCallback onSkip;
  final bool autoSkipActive;
  final bool frozen;
  final int countdownSeconds;

  const SkipIntroButton({
    super.key,
    required this.onSkip,
    this.autoSkipActive = false,
    this.frozen = false,
    this.countdownSeconds = EpisodeNavigationController.autoSkipIntroSeconds,
  });

  @override
  State<SkipIntroButton> createState() => _SkipIntroButtonState();
}

class _SkipIntroButtonState extends State<SkipIntroButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(
      seconds: EpisodeNavigationController.autoSkipIntroSeconds,
    ),
  );

  bool get _counting => widget.autoSkipActive && !widget.frozen;

  @override
  void initState() {
    super.initState();
    if (_counting) _progress.forward();
  }

  @override
  void didUpdateWidget(SkipIntroButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_counting && !_progress.isAnimating && _progress.value == 0) {
      _progress.forward();
    } else if (!_counting && _progress.isAnimating) {
      // Frozen, not rewound: the bar stays where the viewer stopped it.
      _progress.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 170,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onSkip,
          borderRadius: BorderRadius.circular(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter.grouped(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Stack(
                  children: [
                    if (_counting)
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _progress,
                          builder: (context, _) => Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: _progress.value,
                              child: ColoredBox(
                                color:
                                    AppColors.primary.withValues(alpha: 0.22),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            "Passer l'intro",
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (_counting) ...[
                            const SizedBox(width: 10),
                            Text(
                              '${widget.countdownSeconds}s',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.skip_next_rounded,
                            color: AppColors.textPrimary,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
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
