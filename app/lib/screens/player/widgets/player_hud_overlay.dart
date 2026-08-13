import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'player_top_bar.dart';

class PlayerHUDOverlay extends StatelessWidget {
  final bool visible;
  final GlobalKey? timelineAnchorKey;
  final mk.Player player;
  final dynamic media; // Can be Media or HomeMediaItem
  final String mediaTitle;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final Duration position;
  final Duration duration;
  final bool isDraggingSlider;
  final double dragValue;
  final VoidCallback onToggleControls;
  final VoidCallback onHideControlsWithDelay;
  final void Function(int) onSeekRelative;
  final VoidCallback onBack;
  final VoidCallback? onShowTrackSettings;
  final void Function(double) onSliderChangeStart;
  final void Function(double) onSliderChanged;
  final void Function(double) onSliderChangeEnd;
  final VoidCallback? onNextEpisode;

  const PlayerHUDOverlay({
    super.key,
    required this.visible,
    this.timelineAnchorKey,
    required this.player,
    required this.media,
    required this.mediaTitle,
    required this.isPlaying,
    required this.onPlayPause,
    required this.position,
    required this.duration,
    required this.isDraggingSlider,
    required this.dragValue,
    required this.onToggleControls,
    required this.onHideControlsWithDelay,
    required this.onSeekRelative,
    required this.onBack,
    this.onShowTrackSettings,
    required this.onSliderChangeStart,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    this.onNextEpisode,
  });

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
    final rawPos = isDraggingSlider
        ? Duration(seconds: dragValue.toInt())
        : position;
    final totalDuration =
        duration.inSeconds > 0 ? duration : const Duration(seconds: 1);
    // ProgressBar asserts progress <= total and throws otherwise. A transient
    // disagreement between the two — a stale position arriving against a
    // freshly changed duration during an HLS session swap — would then raise on
    // every frame, and the resulting exception storm wedges the whole overlay.
    // Clamping keeps a momentary inconsistency cosmetic instead of fatal.
    final currentPos = rawPos > totalDuration ? totalDuration : rawPos;

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
                title: mediaTitle,
                onBack: onBack,
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
                        KeyedSubtree(
                          key: timelineAnchorKey,
                          child: Row(
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
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: _DragProgressBar(
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
                                  thumbRadius: 8,
                                  barHeight: 5,
                                  timeLabelLocation: TimeLabelLocation.none,
                                  isPlaying: isPlaying,
                                  onPlayPause: onPlayPause,
                                  onSliderChangeStart: onSliderChangeStart,
                                  onSliderChanged: onSliderChanged,
                                  onSliderChangeEnd: onSliderChangeEnd,
                                  onHideControlsWithDelay: onHideControlsWithDelay,
                                ),
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
                                onTap: onPlayPause,
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
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 120),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    transitionBuilder: (child, animation) =>
                                        ScaleTransition(scale: animation, child: child),
                                    child: Icon(
                                      isPlaying ? Icons.pause : Icons.play_arrow,
                                      key: ValueKey(isPlaying),
                                      color: Colors.white,
                                      size: 28,
                                    ),
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

class _DragProgressBar extends StatefulWidget {
  final Duration progress;
  final Duration buffered;
  final Duration total;
  final Color? progressBarColor;
  final Color? baseBarColor;
  final Color? bufferedBarColor;
  final Color? thumbColor;
  final Color? thumbGlowColor;
  final double thumbRadius;
  final double barHeight;
  final TimeLabelLocation? timeLabelLocation;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final void Function(double) onSliderChangeStart;
  final void Function(double) onSliderChanged;
  final void Function(double) onSliderChangeEnd;
  final VoidCallback onHideControlsWithDelay;

  const _DragProgressBar({
    required this.progress,
    required this.buffered,
    required this.total,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onSliderChangeStart,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    required this.onHideControlsWithDelay,
    this.progressBarColor,
    this.baseBarColor,
    this.bufferedBarColor,
    this.thumbColor,
    this.thumbGlowColor,
    this.thumbRadius = 8,
    this.barHeight = 5,
    this.timeLabelLocation,
  });

  @override
  State<_DragProgressBar> createState() => _DragProgressBarState();
}

class _DragProgressBarState extends State<_DragProgressBar> {
  bool _wasPlaying = false;
  bool _hasMoved = false;

  void _handleStart(ThumbDragDetails details) {
    _wasPlaying = widget.isPlaying;
    _hasMoved = false;
    widget.onSliderChangeStart(details.timeStamp.inSeconds.toDouble());
  }

  void _handleUpdate(ThumbDragDetails details) {
    if (!_hasMoved) {
      _hasMoved = true;
      if (_wasPlaying) widget.onPlayPause();
    }
    widget.onSliderChanged(details.timeStamp.inSeconds.toDouble());
  }

  void _handleEnd(Duration position) {
    widget.onSliderChangeEnd(position.inSeconds.toDouble());
    widget.onHideControlsWithDelay();
    if (_hasMoved && _wasPlaying) {
      widget.onPlayPause();
    }
    _hasMoved = false;
  }

  @override
  Widget build(BuildContext context) {
    return ProgressBar(
      progress: widget.progress,
      buffered: widget.buffered,
      total: widget.total,
      progressBarColor: widget.progressBarColor,
      baseBarColor: widget.baseBarColor,
      bufferedBarColor: widget.bufferedBarColor,
      thumbColor: widget.thumbColor,
      thumbGlowColor: widget.thumbGlowColor,
      thumbRadius: widget.thumbRadius,
      barHeight: widget.barHeight,
      timeLabelLocation: widget.timeLabelLocation,
      onDragStart: _handleStart,
      onDragUpdate: _handleUpdate,
      onSeek: _handleEnd,
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
