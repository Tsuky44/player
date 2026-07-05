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

  /// Key to anchor the subtitles popup above the subtitles button.
  final GlobalKey? subtitlesButtonKey;

  /// Key attached to the lowest progress/timeline control for subtitle positioning.
  final GlobalKey? timelineAnchorKey;

  /// Called with a target fraction (0.0 -> 1.0) when the user seeks.
  final ValueChanged<double> onSeekFraction;

  /// Media title for the [mediaTitle] control.
  final String? mediaTitle;

  /// TMDB logo for the [mediaLogo] control.
  final String? mediaLogoUrl;

  /// Current volume 0.0 -> 100.0 (for volumeSlider).
  final double? volume;

  /// Called when the user drags the volume slider.
  final ValueChanged<double>? onVolumeChanged;

  /// Called when the back button is tapped.
  final VoidCallback? onBack;

  /// Opens the up-next episode panel (series only).
  final VoidCallback? onOpenUpNext;

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
    this.subtitlesButtonKey,
    this.timelineAnchorKey,
    this.mediaTitle,
    this.mediaLogoUrl,
    this.volume,
    this.onVolumeChanged,
    this.onBack,
    this.onOpenUpNext,
  });

  VoidCallback? _tapHandler(PlayerControlType type) {
    return switch (type) {
      PlayerControlType.back => onBack,
      PlayerControlType.rewind => onRewind,
      PlayerControlType.forward => onForward,
      PlayerControlType.playPause || PlayerControlType.progressBar => onPlayPause,
      PlayerControlType.timeline ||
          PlayerControlType.timelineEmby ||
          PlayerControlType.timelineGlassInline =>
        null,
      PlayerControlType.skipPrevious => onSkipPrevious,
      PlayerControlType.skipNext => onSkipNext,
      PlayerControlType.volumeUp => onVolumeUp,
      PlayerControlType.volumeDown => onVolumeDown,
      PlayerControlType.mute => onMute,
      PlayerControlType.fullscreen => onToggleFullscreen,
      PlayerControlType.settings => onOpenSettings,
      PlayerControlType.subtitles => onToggleSubtitles,
      PlayerControlType.upNext || PlayerControlType.upNextEmby => onOpenUpNext,
      PlayerControlType.mediaTitle || PlayerControlType.mediaLogo || PlayerControlType.volumeSlider => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final timelineAnchorId = _timelineAnchorId();

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasSize = constraints.biggest;
          return Stack(
            children: [
              for (final placed in config.controls)
                _positioned(placed, canvasSize, timelineAnchorId),
            ],
          );
        },
      ),
    );
  }

  PlacedControl? _primaryTimelineBar() {
    PlacedControl? bottomTimeline;
    for (final placed in config.controls) {
      if (!placed.type.isTimelineBar) continue;
      if (bottomTimeline == null ||
          placed.config.yPercentage > bottomTimeline.config.yPercentage) {
        bottomTimeline = placed;
      }
    }
    return bottomTimeline;
  }

  String? _timelineAnchorId() {
    if (timelineAnchorKey == null) return null;

    PlacedControl? bottomTimeline;
    for (final placed in config.controls) {
      if (!placed.type.isProgressBar) continue;
      if (bottomTimeline == null ||
          placed.config.yPercentage > bottomTimeline.config.yPercentage) {
        bottomTimeline = placed;
      }
    }
    return bottomTimeline?.id;
  }

  bool _isPrimaryTimeline(PlacedControl placed) =>
      _primaryTimelineBar()?.id == placed.id;

  bool _timelineHasEmbeddedSettings() {
    final primary = _primaryTimelineBar();
    return primary != null &&
        _resolvedTimelineOptions(primary).showSettings;
  }

  bool _attachSettingsKeyToTimeline(PlacedControl placed) {
    return settingsButtonKey != null &&
        _isPrimaryTimeline(placed) &&
        _resolvedTimelineOptions(placed).showSettings;
  }

  bool _attachSettingsKeyToStandalone(PlacedControl placed) {
    return settingsButtonKey != null &&
        !_timelineHasEmbeddedSettings() &&
        placed.type == PlayerControlType.settings;
  }

  bool _timelineHasEmbeddedSubtitles() {
    final primary = _primaryTimelineBar();
    return primary != null &&
        _resolvedTimelineOptions(primary).showSubtitles;
  }

  bool _attachSubtitlesKeyToTimeline(PlacedControl placed) {
    return subtitlesButtonKey != null &&
        _isPrimaryTimeline(placed) &&
        _resolvedTimelineOptions(placed).showSubtitles;
  }

  bool _attachSubtitlesKeyToStandalone(PlacedControl placed) {
    return subtitlesButtonKey != null &&
        !_timelineHasEmbeddedSubtitles() &&
        placed.type == PlayerControlType.subtitles;
  }

  /// Resolves saved timeline options, or type defaults when none were stored.
  TimelineChromeOptions _resolvedTimelineOptions(PlacedControl placed) =>
      placed.effectiveTimelineOptions;

  Widget _positioned(
    PlacedControl placed,
    Size canvasSize,
    String? timelineAnchorId,
  ) {
    final c = placed.config;
    final timelineOpts = _resolvedTimelineOptions(placed);
    final chrome = ControlChrome(
      type: placed.type,
      sizePercentage: c.sizePercentage,
      canvasSize: canvasSize,
      widthPercentage: c.widthPercentage,
      variant: ControlChromeVariant.live,
      isPlaying: isPlaying,
      progress: progress,
      duration: placed.type.isTimelineBar ? duration : null,
      currentSeconds: placed.type.isTimelineBar ? currentSeconds : null,
      onSeekFraction: placed.type.isProgressBar || placed.type.isTimelineBar
          ? onSeekFraction
          : null,
      timelineOptions: placed.type.isTimelineBar
          ? timelineOpts
          : const TimelineChromeOptions(showFullscreen: true),
      onPlayPause: placed.type.isTimelineBar ? onPlayPause : null,
      onRewind: placed.type.isTimelineBar ? onRewind : null,
      onForward: placed.type.isTimelineBar ? onForward : null,
      onSkipPrevious: placed.type.isTimelineBar ? onSkipPrevious : null,
      onSkipNext: placed.type.isTimelineBar ? onSkipNext : null,
      onOpenSettings: placed.type.isTimelineBar ? onOpenSettings : null,
      onToggleSubtitles: placed.type.isTimelineBar ? onToggleSubtitles : null,
      onOpenUpNext: placed.type.isTimelineBar ? onOpenUpNext : null,
      onToggleFullscreen: placed.type.isTimelineBar ? onToggleFullscreen : null,
      settingsButtonKey:
          _attachSettingsKeyToTimeline(placed) ? settingsButtonKey : null,
      subtitlesButtonKey:
          _attachSubtitlesKeyToTimeline(placed) ? subtitlesButtonKey : null,
      mediaTitle: placed.type == PlayerControlType.mediaTitle ||
              placed.type == PlayerControlType.mediaLogo
          ? mediaTitle
          : null,
      mediaLogoUrl: placed.type == PlayerControlType.mediaLogo ? mediaLogoUrl : null,
      volume: placed.type == PlayerControlType.volumeSlider ? volume : null,
      onVolumeChanged: placed.type == PlayerControlType.volumeSlider ? onVolumeChanged : null,
      onBack: placed.type == PlayerControlType.back ? onBack : null,
      blurSigma: config.blurIntensity,
      glassOpacity: config.glassOpacity,
      liquidGlass: config.liquidGlass,
    );

    final handler = _tapHandler(placed.type);

    Widget child = placed.type == PlayerControlType.progressBar
        ? _SeekableBar(onSeekFraction: onSeekFraction, child: chrome)
        : placed.type.isTimelineBar
            ? chrome
            : handler != null
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: handler,
                    child: chrome,
                  )
                : chrome;

    if (_attachSettingsKeyToStandalone(placed)) {
      child = KeyedSubtree(key: settingsButtonKey, child: child);
    }

    if (_attachSubtitlesKeyToStandalone(placed)) {
      child = KeyedSubtree(key: subtitlesButtonKey, child: child);
    }

    if (timelineAnchorKey != null &&
        timelineAnchorId != null &&
        placed.id == timelineAnchorId) {
      child = KeyedSubtree(key: timelineAnchorKey, child: child);
    }

    if (placed.type == PlayerControlType.timelineEmby ||
        placed.type == PlayerControlType.timelineGlassInline) {
      return Align(
        alignment: Alignment(0, c.yPercentage * 2 - 1),
        widthFactor: 1.0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: child,
        ),
      );
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
