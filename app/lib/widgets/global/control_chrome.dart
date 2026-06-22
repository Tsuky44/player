import 'dart:ui';
import 'package:flutter/material.dart';
import '../../models/player_layout.dart';

/// Rendering mode for [ControlChrome].
///
/// - [studio]: static preview used on the editing canvas (no playback logic).
/// - [live]: real, interactive control rendered over the video.
enum ControlChromeVariant { studio, live }

const Color _kAccent = Color(0xFF007AFF);

/// Single source of truth for how a modular control LOOKS, shared by the
/// Player Studio (preview) and the real player (live). Behaviour is injected
/// from the outside so the visual stays identical across both surfaces.
class ControlChrome extends StatelessWidget {
  final PlayerControlType type;

  /// Relative size as a fraction of the shortest screen side
  /// (0.03 -> 0.12). Controls icon diameter and progress bar height.
  final double sizePercentage;

  /// The actual canvas size used to convert [sizePercentage] into pixels.
  final Size canvasSize;

  /// Relative width for the progress bar (0.0 -> 1.0 of parent width).
  final double widthPercentage;

  final ControlChromeVariant variant;

  /// Highlight ring shown when this control is selected in the studio.
  final bool selected;

  /// Whether the play button shows the pause glyph (live variant only).
  final bool isPlaying;

  /// Playback progress 0.0 -> 1.0 for the progress bar preview.
  final double progress;

  /// Total media duration (for timeline control).
  final Duration? duration;

  /// Current playback position in seconds (for timeline control).
  final int? currentSeconds;

  /// Callback for seeking when tapping the progress/timeline bar.
  final ValueChanged<double>? onSeekFraction;

  /// Callback for the integrated fullscreen button in timeline.
  final VoidCallback? onToggleFullscreen;

  /// Media title displayed by the [mediaTitle] control.
  final String? mediaTitle;

  /// Current volume 0.0 -> 100.0 (for volumeSlider).
  final double? volume;

  /// Called when the user drags the volume slider.
  final ValueChanged<double>? onVolumeChanged;

  /// Called when the back button is tapped.
  final VoidCallback? onBack;

  const ControlChrome({
    super.key,
    required this.type,
    required this.sizePercentage,
    required this.canvasSize,
    this.widthPercentage = 0.85,
    this.variant = ControlChromeVariant.studio,
    this.selected = false,
    this.isPlaying = false,
    this.progress = 0.35,
    this.duration,
    this.currentSeconds,
    this.onSeekFraction,
    this.onToggleFullscreen,
    this.mediaTitle,
    this.volume,
    this.onVolumeChanged,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = switch (type) {
      PlayerControlType.progressBar => _buildProgressBar(),
      PlayerControlType.timeline => _buildTimelineBar(),
      PlayerControlType.mediaTitle => _buildMediaTitle(),
      PlayerControlType.volumeSlider => _buildVolumeSlider(context),
      _ => _buildIconButton(),
    };

    if (variant == ControlChromeVariant.studio) {
      child = AbsorbPointer(child: child);
    }

    return child;
  }

  IconData get _icon {
    switch (type) {
      case PlayerControlType.rewind:
        return Icons.replay_10;
      case PlayerControlType.forward:
        return Icons.forward_10;
      case PlayerControlType.playPause:
        return isPlaying ? Icons.pause : Icons.play_arrow;
      case PlayerControlType.progressBar:
        return Icons.linear_scale;
      case PlayerControlType.skipPrevious:
        return Icons.skip_previous;
      case PlayerControlType.skipNext:
        return Icons.skip_next;
      case PlayerControlType.volumeUp:
        return Icons.volume_up;
      case PlayerControlType.volumeDown:
        return Icons.volume_down;
      case PlayerControlType.mute:
        return Icons.volume_off;
      case PlayerControlType.fullscreen:
        return Icons.fullscreen;
      case PlayerControlType.settings:
        return Icons.settings;
      case PlayerControlType.subtitles:
        return Icons.subtitles;
      case PlayerControlType.timeline:
        return Icons.timeline;
      case PlayerControlType.back:
        return Icons.arrow_back;
      case PlayerControlType.mediaTitle:
        return Icons.title;
      case PlayerControlType.volumeSlider:
        return Icons.volume_down;
    }
  }

  Widget _glass({required Widget child, required BorderRadius radius}) {
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: radius,
            border: Border.all(
              color: selected ? _kAccent : Colors.white.withOpacity(0.18),
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [BoxShadow(color: _kAccent.withOpacity(0.45), blurRadius: 16)]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }

  double get _pixelSize => canvasSize.shortestSide * sizePercentage;

  Widget _buildIconButton() {
    final double pixelSize = _pixelSize;
    final double diameter = pixelSize * 1.4; // proportional padding
    return _glass(
      radius: BorderRadius.circular(diameter / 2),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Icon(_icon, color: Colors.white, size: pixelSize),
      ),
    );
  }

  Widget _buildProgressBar() {
    final double height = (_pixelSize * 0.4).clamp(10.0, 32.0);
    return _glass(
      radius: BorderRadius.circular(height / 2 + 8),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: (height / 2).clamp(8.0, 16.0),
        ),
        child: FractionallySizedBox(
          widthFactor: widthPercentage.clamp(0.1, 1.0),
          child: SizedBox(
            height: height,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: _kAccent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(progress.clamp(0.0, 1.0) * 2 - 1, 0),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineBar() {
    final double height = (_pixelSize * 0.5).clamp(14.0, 40.0);
    final totalSec = duration?.inSeconds ?? 3600;
    final current = (currentSeconds ?? 0).clamp(0, totalSec);
    final remaining = totalSec - current;
    final frac = totalSec > 0 ? current / totalSec : 0.0;

    final timeStyle = TextStyle(
      color: Colors.white.withOpacity(0.9),
      fontSize: (height * 0.45).clamp(10.0, 16.0),
      fontWeight: FontWeight.w500,
    );

    Widget bar = SizedBox(
      height: height * 0.55,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          FractionallySizedBox(
            widthFactor: frac.clamp(0.0, 1.0),
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: _kAccent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Align(
            alignment: Alignment(frac.clamp(0.0, 1.0) * 2 - 1, 0),
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );

    final seekableBar = bar;
    if (onSeekFraction != null) {
      bar = Builder(
        builder: (ctx) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) {
            final box = ctx.findRenderObject() as RenderBox?;
            if (box != null && box.size.width > 0) {
              final fraction = (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
              onSeekFraction!.call(fraction);
            }
          },
          onHorizontalDragUpdate: (d) {
            final box = ctx.findRenderObject() as RenderBox?;
            if (box != null && box.size.width > 0) {
              final fraction = (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
              onSeekFraction!.call(fraction);
            }
          },
          child: seekableBar,
        ),
      );
    }

    return _glass(
      radius: BorderRadius.circular(height / 2 + 6),
      child: SizedBox(
        width: canvasSize.width * widthPercentage.clamp(0.3, 1.0),
        height: height,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Text(_formatDuration(Duration(seconds: current)), style: timeStyle),
            const SizedBox(width: 10),
            Expanded(child: bar),
            const SizedBox(width: 10),
            Text(
              '-${_formatDuration(Duration(seconds: remaining))} / ${_formatEndTime(remaining)}',
              style: timeStyle.copyWith(
                color: Colors.white.withOpacity(0.7),
                fontSize: (height * 0.38).clamp(9.0, 13.0),
              ),
            ),
            const SizedBox(width: 8),
            if (onToggleFullscreen != null)
              GestureDetector(
                onTap: onToggleFullscreen,
                child: Icon(
                  Icons.fullscreen,
                  color: Colors.white.withOpacity(0.85),
                  size: (height * 0.7).clamp(16.0, 24.0),
                ),
              ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaTitle() {
    final double height = (_pixelSize * 0.8).clamp(24.0, 48.0);
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              mediaTitle ?? 'Titre du média',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: (height * 0.45).clamp(12.0, 18.0),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeSlider(BuildContext context) {
    final double height = (_pixelSize * 0.5).clamp(16.0, 40.0);
    final double width = canvasSize.width * widthPercentage.clamp(0.05, 0.5);
    return _VolumeSliderButton(
      height: height,
      width: width,
      forceExpanded: variant == ControlChromeVariant.studio,
      volume: volume,
      onVolumeChanged: onVolumeChanged,
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _formatEndTime(int remainingSeconds) {
    final end = DateTime.now().add(Duration(seconds: remainingSeconds));
    return '${end.hour}h${end.minute.toString().padLeft(2, '0')}';
  }
}

/// Compact volume button that expands to reveal a slider on hover.
/// In studio mode [forceExpanded] keeps it open so the designer can see
/// the slider and resize the control.
class _VolumeSliderButton extends StatefulWidget {
  final double height;
  final double width;
  final bool forceExpanded;
  final double? volume;
  final ValueChanged<double>? onVolumeChanged;

  const _VolumeSliderButton({
    required this.height,
    required this.width,
    this.forceExpanded = false,
    this.volume,
    this.onVolumeChanged,
  });

  @override
  State<_VolumeSliderButton> createState() => _VolumeSliderButtonState();
}

class _VolumeSliderButtonState extends State<_VolumeSliderButton> {
  bool _hovering = false;

  bool get _expanded => widget.forceExpanded || _hovering;

  @override
  Widget build(BuildContext context) {
    final vol = (widget.volume ?? 50.0).clamp(0.0, 100.0);
    final iconSize = (widget.height * 0.55).clamp(14.0, 22.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: _expanded ? widget.width : widget.height,
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A).withOpacity(0.6),
          borderRadius: BorderRadius.circular(widget.height / 2 + 6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: widget.height,
              height: widget.height,
              child: InkWell(
                onTap: () {
                  if (widget.onVolumeChanged != null) {
                    widget.onVolumeChanged!(vol <= 0 ? 100 : 0);
                  }
                },
                borderRadius: BorderRadius.circular(widget.height / 2),
                child: Center(
                  child: Icon(
                    vol == 0 ? Icons.volume_off : vol < 50 ? Icons.volume_down : Icons.volume_up,
                    color: Colors.white.withOpacity(0.85),
                    size: iconSize,
                  ),
                ),
              ),
            ),
            if (_expanded)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5, elevation: 0, pressedElevation: 0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                      activeTrackColor: const Color(0xFF007AFF),
                      inactiveTrackColor: Colors.white.withOpacity(0.25),
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: vol,
                      min: 0,
                      max: 100,
                      onChanged: widget.onVolumeChanged,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
