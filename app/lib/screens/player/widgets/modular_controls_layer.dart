import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import '../../../widgets/global/control_chrome.dart';

/// Real, interactive control layer driven by a [PlayerLayoutConfig].
class ModularControlsLayer extends StatelessWidget {
  final PlayerLayoutConfig config;
  final bool visible;
  final bool isPlaying;
  final double progress;

  /// Total media duration and current position for the timeline control.
  final Duration? duration;
  final int? currentSeconds;

  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;
  final VoidCallback? onVolumeUp;
  final VoidCallback? onVolumeDown;
  final VoidCallback? onMute;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onToggleSubtitles;

  /// Key to anchor the settings popup above the settings button.
  final GlobalKey? settingsButtonKey;

  /// Called with a target fraction (0.0 -> 1.0) when the user seeks.
  final ValueChanged<double> onSeekFraction;

  /// Media title for the [mediaTitle] control.
  final String? mediaTitle;

  /// Current volume 0.0 -> 100.0 (for volumeSlider).
  final double? volume;

  /// Called when the user drags the volume slider.
  final ValueChanged<double>? onVolumeChanged;

  /// Called when the back button is tapped.
  final VoidCallback? onBack;

  const ModularControlsLayer({
    super.key,
    required this.config,
    required this.visible,
    required this.isPlaying,
    required this.progress,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onSeekFraction,
    this.duration,
    this.currentSeconds,
    this.onSkipPrevious,
    this.onSkipNext,
    this.onVolumeUp,
    this.onVolumeDown,
    this.onMute,
    this.onToggleFullscreen,
    this.onOpenSettings,
    this.onToggleSubtitles,
    this.settingsButtonKey,
    this.mediaTitle,
    this.volume,
    this.onVolumeChanged,
    this.onBack,
  });

  VoidCallback? _tapHandler(PlayerControlType type) {
    return switch (type) {
      PlayerControlType.back => onBack,
      PlayerControlType.rewind => onRewind,
      PlayerControlType.forward => onForward,
      PlayerControlType.playPause || PlayerControlType.progressBar || PlayerControlType.timeline => onPlayPause,
      PlayerControlType.skipPrevious => onSkipPrevious,
      PlayerControlType.skipNext => onSkipNext,
      PlayerControlType.volumeUp => onVolumeUp,
      PlayerControlType.volumeDown => onVolumeDown,
      PlayerControlType.mute => onMute,
      PlayerControlType.fullscreen => onToggleFullscreen,
      PlayerControlType.settings => onOpenSettings,
      PlayerControlType.subtitles => onToggleSubtitles,
      PlayerControlType.mediaTitle || PlayerControlType.volumeSlider => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final canvasSize = constraints.biggest;
              return Stack(
                children: [
                  for (final placed in config.controls)
                    _positioned(placed, canvasSize),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _positioned(PlacedControl placed, Size canvasSize) {
    final c = placed.config;
    final chrome = ControlChrome(
      type: placed.type,
      sizePercentage: c.sizePercentage,
      canvasSize: canvasSize,
      widthPercentage: c.widthPercentage,
      variant: ControlChromeVariant.live,
      isPlaying: isPlaying,
      progress: progress,
      duration: placed.type == PlayerControlType.timeline ? duration : null,
      currentSeconds: placed.type == PlayerControlType.timeline ? currentSeconds : null,
      onSeekFraction: placed.type.isProgressBar ? onSeekFraction : null,
      onToggleFullscreen: placed.type == PlayerControlType.timeline ? onToggleFullscreen : null,
      mediaTitle: placed.type == PlayerControlType.mediaTitle ? mediaTitle : null,
      volume: placed.type == PlayerControlType.volumeSlider ? volume : null,
      onVolumeChanged: placed.type == PlayerControlType.volumeSlider ? onVolumeChanged : null,
      onBack: placed.type == PlayerControlType.back ? onBack : null,
    );

    final handler = _tapHandler(placed.type);

    Widget child = placed.type == PlayerControlType.progressBar
        ? _SeekableBar(onSeekFraction: onSeekFraction, child: chrome)
        : handler != null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: handler,
                child: chrome,
              )
            : chrome;

    if (placed.type == PlayerControlType.settings && settingsButtonKey != null) {
      child = KeyedSubtree(key: settingsButtonKey, child: child);
    }

    return Align(
      alignment: Alignment(c.xPercentage * 2 - 1, c.yPercentage * 2 - 1),
      child: child,
    );
  }
}

/// Wraps the progress chrome and converts horizontal taps/drags into a
/// 0.0 -> 1.0 seek fraction based on its own rendered width.
class _SeekableBar extends StatelessWidget {
  final ValueChanged<double> onSeekFraction;
  final Widget child;

  const _SeekableBar({required this.onSeekFraction, required this.child});

  void _emit(BuildContext context, Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return;
    final fraction = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
    onSeekFraction(fraction);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _emit(context, d.localPosition),
      onHorizontalDragUpdate: (d) => _emit(context, d.localPosition),
      child: child,
    );
  }
}
