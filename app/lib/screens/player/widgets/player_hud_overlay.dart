import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:media_kit/media_kit.dart' as mk;
import '../../../models/models.dart';
import 'player_top_bar.dart';

class PlayerHUDOverlay extends StatelessWidget {
  final bool visible;
  final mk.Player player;
  final dynamic media; // Can be Media or HomeMediaItem
  final Duration position;
  final Duration duration;
  final bool isDraggingSlider;
  final double dragValue;
  final VoidCallback onToggleControls;
  final VoidCallback onHideControlsWithDelay;
  final void Function(int) onSeekRelative;
  final VoidCallback? onShowTrackSettings;
  final void Function(double) onSliderChangeStart;
  final void Function(double) onSliderChanged;
  final void Function(double) onSliderChangeEnd;
  final VoidCallback? onNextEpisode;

  const PlayerHUDOverlay({
    super.key,
    required this.visible,
    required this.player,
    required this.media,
    required this.position,
    required this.duration,
    required this.isDraggingSlider,
    required this.dragValue,
    required this.onToggleControls,
    required this.onHideControlsWithDelay,
    required this.onSeekRelative,
    this.onShowTrackSettings,
    required this.onSliderChangeStart,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    this.onNextEpisode,
  });

  Media get _actualMedia {
    if (media is HomeMediaItem) {
      return (media as HomeMediaItem).media;
    }
    return media as Media;
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    final secStr = seconds.toString().padLeft(2, '0');
    final minStr = minutes.toString().padLeft(2, '0');
    if (hours > 0) return "$hours:$minStr:$secStr";
    return "$minStr:$secStr";
  }

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    const accentBlue = Color(0xFF007AFF);
    final currentPos = isDraggingSlider
        ? Duration(seconds: dragValue.toInt())
        : position;
    final totalDuration = duration.inSeconds > 0 ? duration : const Duration(seconds: 1);

    return Positioned.fill(
      child: GestureDetector(
        onTap: onToggleControls,
        child: Container(
          color: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              // TOP BAR - Title only
              PlayerTopBar(
                title: _actualMedia.title,
                onBack: () => Navigator.of(context).pop(),
              ),

              const Spacer(),

              // BOTTOM GLASS PANEL
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A).withOpacity(0.6),
                      borderRadius: BorderRadius.circular(24),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withOpacity(0.15),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Progress bar with time
                        Row(
                          children: [
                            Text(
                              _formatDuration(currentPos),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                                fontFamily: 'Geist',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ProgressBar(
                                progress: currentPos,
                                buffered: currentPos + const Duration(seconds: 30) > totalDuration
                                    ? totalDuration
                                    : currentPos + const Duration(seconds: 30),
                                total: totalDuration,
                                progressBarColor: accentBlue,
                                baseBarColor: Colors.white.withOpacity(0.2),
                                bufferedBarColor: Colors.white.withOpacity(0.35),
                                thumbColor: Colors.white,
                                thumbGlowColor: Colors.white.withOpacity(0.3),
                                thumbRadius: 6,
                                barHeight: 4,
                                timeLabelLocation: TimeLabelLocation.none,
                                onSeek: (newPos) {
                                  onSliderChangeStart(newPos.inSeconds.toDouble());
                                  onSliderChanged(newPos.inSeconds.toDouble());
                                  onSliderChangeEnd(newPos.inSeconds.toDouble());
                                  onHideControlsWithDelay();
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _formatDuration(duration),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                                fontFamily: 'Geist',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Control buttons row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _GlassIconButton(
                              icon: Icons.replay_10,
                              onPressed: () => onSeekRelative(-10),
                              size: 24,
                            ),
                            const SizedBox(width: 20),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  if (player.state.playing) {
                                    player.pause();
                                  } else {
                                    player.play();
                                  }
                                  onHideControlsWithDelay();
                                },
                                borderRadius: BorderRadius.circular(28),
                                child: Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(28),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.2),
                                      width: 1,
                                    ),
                                  ),
                                  child: Icon(
                                    player.state.playing ? Icons.pause : Icons.play_arrow,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            _GlassIconButton(
                              icon: Icons.forward_10,
                              onPressed: () => onSeekRelative(10),
                              size: 24,
                            ),
                            const SizedBox(width: 24),
                            if (onNextEpisode != null)
                              _GlassIconButton(
                                icon: Icons.skip_next,
                                onPressed: onNextEpisode,
                                size: 22,
                              ),
                            if (onNextEpisode != null)
                              const SizedBox(width: 24),
                            _GlassIconButton(
                              icon: Icons.fullscreen,
                              onPressed: () {},
                              size: 22,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ]
                .animate(interval: 40.ms)
                .fadeIn(duration: 300.ms, curve: Curves.easeOut)
                .slideY(begin: 0.05, end: 0, duration: 300.ms, curve: Curves.easeOut),
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  const _GlassIconButton({
    required this.icon,
    this.onPressed,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: size,
          ),
        ),
      ),
    );
  }
}
