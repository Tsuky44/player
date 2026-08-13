import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';

class NextEpisodeOverlay extends StatefulWidget {
  final HomeMediaItem? nextEpisode;
  final bool autoPlayActive;
  final bool frozen;
  final int countdownSeconds;
  final VoidCallback onPlayNext;
  final VoidCallback onCancel;

  const NextEpisodeOverlay({
    super.key,
    required this.nextEpisode,
    required this.autoPlayActive,
    required this.frozen,
    required this.countdownSeconds,
    required this.onPlayNext,
    required this.onCancel,
  });

  @override
  State<NextEpisodeOverlay> createState() => _NextEpisodeOverlayState();
}

class _NextEpisodeOverlayState extends State<NextEpisodeOverlay>
    with TickerProviderStateMixin {
  AnimationController? _animationController;

  @override
  void initState() {
    super.initState();
    if (widget.autoPlayActive) {
      _startAnimation();
    }
  }

  @override
  void didUpdateWidget(NextEpisodeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.autoPlayActive && !oldWidget.autoPlayActive) {
      _startAnimation();
    } else if (!widget.autoPlayActive &&
        oldWidget.autoPlayActive &&
        !widget.frozen) {
      _stopAnimation();
    }

    if (widget.frozen && !oldWidget.frozen) {
      _animationController?.stop(canceled: false);
      setState(() {});
    } else if (!widget.frozen && oldWidget.frozen && widget.autoPlayActive) {
      _startAnimation();
    }
  }

  void _startAnimation() {
    _animationController?.dispose();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _animationController!.forward().whenComplete(() {
      if (mounted && widget.autoPlayActive && !widget.frozen) {
        widget.onPlayNext();
      }
    });
    setState(() {});
  }

  void _stopAnimation() {
    _animationController?.stop();
    _animationController?.dispose();
    _animationController = null;
    setState(() {});
  }

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 190,
      right: 32,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: widget.onPlayNext,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                height: 48,
                constraints: const BoxConstraints(minWidth: 188),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surface.withValues(alpha: 0.78),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (widget.autoPlayActive &&
                        !widget.frozen &&
                        _animationController != null)
                      AnimatedBuilder(
                        animation: _animationController!,
                        builder: (context, child) {
                          return Positioned.fill(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: _animationController!.value,
                                child: Container(
                                  color:
                                      AppColors.primary.withValues(alpha: 0.22),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.frozen
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: AppColors.textPrimary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            widget.frozen
                                ? 'Lecture auto.'
                                : 'Épisode suivant',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (widget.autoPlayActive && !widget.frozen) ...[
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
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: widget.onCancel,
                            child: const Icon(
                              Icons.close_rounded,
                              color: AppColors.textSecondary,
                              size: 18,
                            ),
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
