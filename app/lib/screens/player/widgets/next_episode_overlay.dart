import 'package:flutter/material.dart';
import '../../../models/models.dart';

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
    } else if (!widget.autoPlayActive && oldWidget.autoPlayActive && !widget.frozen) {
      _stopAnimation();
    }

    if (widget.frozen && !oldWidget.frozen) {
      _animationController?.stop(canceled: false);
      setState(() {});
    } else if (!widget.frozen && oldWidget.frozen && widget.autoPlayActive) {
      // Relancer l'animation quand on sort du freeze
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
          child: Container(
            height: 48,
            constraints: const BoxConstraints(minWidth: 180),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: Colors.transparent,
              border: Border.all(
                color: Colors.white.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Progressive fill from left to right
                  if (widget.autoPlayActive && !widget.frozen && _animationController != null)
                    AnimatedBuilder(
                      animation: _animationController!,
                      builder: (context, child) {
                        return Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: _animationController!.value,
                              child: Container(
                                color: const Color(0xFF333333),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  // Content
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.frozen ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          widget.frozen
                              ? "Lecture auto."
                              : "Épisode suivant",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                        if (widget.autoPlayActive && !widget.frozen) ...[
                          const SizedBox(width: 10),
                          Text(
                            "${widget.countdownSeconds}s",
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: widget.onCancel,
                          child: Icon(
                            Icons.close,
                            color: Colors.white.withOpacity(0.8),
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
    );
  }
}
