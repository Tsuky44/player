import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../../../desktop_window.dart';
import '../../../../utils/format.dart';
import '../../../../widgets/global/app_network_image.dart';
import 'emby_brightness_slider.dart';
import 'emby_chrome_theme.dart';
import 'emby_progress_bar.dart';

/// Hand-written clone of the Emby player chrome.
///
/// Unlike [ModularControlsLayer] nothing here is placed by the user: the
/// arrangement is code, not data, which is what lets it be laid out in real
/// pixels and stay faithful. Player Studio shows it as a frozen preview.
///
/// Two arrangements, one breakpoint ([EmbyChromeTheme.compactBreakpoint]):
/// wide puts the title block and the utility cluster on one row above the
/// scrubber, compact stacks them so nothing collides at phone widths.
class EmbyControlsLayer extends StatelessWidget {
  final bool visible;

  /// Anchors subtitle positioning to the scrubber, as the other layers do.
  final GlobalKey? timelineAnchorKey;

  // --- Playback -----------------------------------------------------------
  final bool isPlaying;
  final Duration position;
  final Duration duration;

  /// Downloaded-ahead fraction, 0.0 -> 1.0.
  final double buffered;

  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final ValueChanged<double> onSeekFraction;
  final ValueChanged<bool>? onScrubbingChanged;

  // --- Identity -----------------------------------------------------------

  /// Bold line: movie title, or show name for an episode.
  final String? title;

  /// Muted line above it: release year for a movie, `S1:E3 - …` for an episode.
  final String? overline;

  final String? logoUrl;

  // --- Volume -------------------------------------------------------------

  /// 0.0 -> 100.0, matching media_kit.
  final double volume;
  final ValueChanged<double> onVolumeChanged;

  // --- Brightness ---------------------------------------------------------

  /// Screen brightness, 0.0 -> 1.0, or null on a screen whose backlight this
  /// app does not drive — a desktop monitor, a television, a browser tab. The
  /// left-hand bar is left out entirely rather than shown doing nothing.
  final double? brightness;
  final ValueChanged<double>? onBrightnessChanged;

  /// True while the bar is being dragged, so the chrome can be held open.
  final ValueChanged<bool>? onBrightnessDraggingChanged;

  // --- Utilities ----------------------------------------------------------
  final VoidCallback onBack;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onOpenAudio;
  final VoidCallback onCycleSpeed;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleFullscreen;
  final double playbackRate;

  // --- Conditional --------------------------------------------------------

  /// Series only — null on a movie or at the end of a season.
  final VoidCallback? onSkipNext;

  /// Series only — null on a movie or on the first episode of a season.
  final VoidCallback? onSkipPrevious;

  /// Opens the episode browser. Series only — null on a movie.
  final VoidCallback? onOpenEpisodes;

  /// Only while an intro chapter is playing.
  final VoidCallback? onSkipIntro;

  /// Chapter starts as fractions, for the scrubber ticks.
  final List<double> chapterMarks;

  final GlobalKey? settingsButtonKey;
  final GlobalKey? subtitlesButtonKey;

  const EmbyControlsLayer({
    super.key,
    required this.visible,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onSeekFraction,
    required this.volume,
    required this.onVolumeChanged,
    this.brightness,
    this.onBrightnessChanged,
    this.onBrightnessDraggingChanged,
    required this.onBack,
    required this.onToggleSubtitles,
    required this.onOpenAudio,
    required this.onCycleSpeed,
    required this.onOpenSettings,
    required this.onToggleFullscreen,
    this.playbackRate = 1.0,
    this.timelineAnchorKey,
    this.onScrubbingChanged,
    this.title,
    this.overline,
    this.logoUrl,
    this.onSkipNext,
    this.onSkipPrevious,
    this.onOpenEpisodes,
    this.onSkipIntro,
    this.chapterMarks = const [],
    this.settingsButtonKey,
    this.subtitlesButtonKey,
  });

  double get _progressFraction {
    final total = duration.inSeconds;
    if (total <= 0) return 0.0;
    return (position.inSeconds / total).clamp(0.0, 1.0);
  }

  int get _remainingSeconds {
    final left = duration.inSeconds - position.inSeconds;
    return left > 0 ? left : 0;
  }

  @override
  Widget build(BuildContext context) {
    // Sized from its own constraints rather than the window, so the Studio can
    // render this same widget shrunk into a preview box and still get the
    // arrangement that box deserves.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final m = EmbyChromeTheme.metricsFor(width);
        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _fadeWithChrome(_buildTop(m, width)),
            ),
            // Between the two scrims, on the edge Netflix and the rest put it.
            // It rides the same fade as the chrome: a bar floating alone over
            // a film nobody is touching is exactly the clutter the auto-hide
            // exists to remove.
            if (brightness != null && onBrightnessChanged != null)
              Positioned(
                left: m.gutter - 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _fadeWithChrome(
                    EmbyBrightnessSlider(
                      value: brightness!,
                      onChanged: onBrightnessChanged!,
                      onDraggingChanged: onBrightnessDraggingChanged,
                      metrics: m,
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Outside the fade on purpose: the intro offer is
                  // time-limited, and a user who simply is not moving the mouse
                  // would watch it expire behind hidden chrome. It keeps its
                  // slot above the bottom bar, so revealing the chrome does not
                  // move it.
                  if (onSkipIntro != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(m.gutter, 0, m.gutter, 14),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _EmbySkipIntroButton(
                            onPressed: onSkipIntro!, metrics: m),
                      ),
                    ),
                  _fadeWithChrome(_buildBottom(m)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Wraps a part of the chrome in the show/hide fade — and takes it out of
  /// hit-testing while it is invisible, so a hidden control cannot be clicked.
  Widget _fadeWithChrome(Widget child) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }

  // --- Top ----------------------------------------------------------------

  Widget _buildTop(EmbyChromeMetrics m, double width) {
    return Container(
      // The macOS traffic lights live in this strip, so the row starts below
      // them instead of underneath.
      padding: EdgeInsets.fromLTRB(
        m.gutter,
        macOSWindowControlsTopInset + 12,
        m.gutter,
        28,
      ),
      decoration: const BoxDecoration(gradient: EmbyChromeTheme.topScrim),
      child: Row(
        children: [
          _EmbyIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            tooltip: 'Retour',
            metrics: m,
            onPressed: onBack,
          ),
          const SizedBox(width: 8),
          Flexible(child: _buildBrand(m)),
          const Spacer(),
          _EmbyVolumeControl(
            volume: volume,
            onChanged: onVolumeChanged,
            metrics: m,
            // Below this the slider squeezes the title out of the top row.
            // The mute button alone still leaves the volume reachable, and
            // the settings sheet carries the fine control.
            showSlider: width >= 560,
          ),
        ],
      ),
    );
  }

  /// TMDB logo when we have one, the title otherwise — never both, and never
  /// an empty gap while the logo request is still in flight.
  Widget _buildBrand(EmbyChromeMetrics m) {
    final url = logoUrl;
    if (url != null && url.isNotEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        // The detail pages render this exact URL — same normalised TMDB size —
        // through the same store, so by the time playback starts the bytes are
        // cached and the decoded frame is still in memory.
        child: AppNetworkImage(
          url: url,
          height: m.isCompact ? 26 : 38,
          fit: BoxFit.contain,
          fadeInDuration: const Duration(milliseconds: 120),
          // Shared decode with the detail header rather than one sized to this
          // 38 px slot — logos are small enough that the full frame is cheaper
          // than a second entry.
          decodeAtSourceSize: true,
          // No spinner and no gap: the title holds the slot until the logo is
          // ready, so the top row never jumps.
          placeholder: _brandText(m),
          errorWidget: _brandText(m),
        ),
      );
    }
    return _brandText(m);
  }

  Widget _brandText(EmbyChromeMetrics m) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: EmbyChromeTheme.title,
          fontSize: m.isCompact ? 15 : 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // --- Bottom -------------------------------------------------------------

  Widget _buildBottom(EmbyChromeMetrics m) {
    return Container(
      padding: EdgeInsets.fromLTRB(m.gutter, 60, m.gutter, m.isCompact ? 16 : 24),
      decoration: const BoxDecoration(gradient: EmbyChromeTheme.bottomScrim),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.isCompact) ...[
            _buildTitleBlock(m),
            const SizedBox(height: 10),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: _buildTitleBlock(m)),
                const SizedBox(width: 24),
                _buildUtilities(m),
              ],
            ),
          const SizedBox(height: 6),
          KeyedSubtree(
            key: timelineAnchorKey,
            child: EmbyProgressBar(
              progress: _progressFraction,
              buffered: buffered,
              duration: duration,
              chapterMarks: chapterMarks,
              metrics: m,
              onSeek: onSeekFraction,
              onScrubbingChanged: onScrubbingChanged,
            ),
          ),
          _buildTimes(m),
          const SizedBox(height: 4),
          // Compact gives the utilities their own centred row: side by side
          // with the transport they need ~414px, which does not fit a phone.
          if (m.isCompact) ...[
            Center(child: _buildTransport(m)),
            const SizedBox(height: 2),
            Center(child: _buildUtilities(m)),
          ] else
            _buildTransport(m),
        ],
      ),
    );
  }

  Widget _buildTitleBlock(EmbyChromeMetrics m) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (overline != null && overline!.isNotEmpty)
          Text(
            overline!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: EmbyChromeTheme.meta,
              fontSize: m.metaSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        const SizedBox(height: 2),
        Text(
          title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: EmbyChromeTheme.title,
            fontSize: m.titleSize,
            fontWeight: FontWeight.w600,
            height: 1.15,
          ),
        ),
      ],
    );
  }

  Widget _buildUtilities(EmbyChromeMetrics m) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Series only: a movie has no episode list to browse.
        if (onOpenEpisodes != null) ...[
          _EmbyIconButton(
            icon: Icons.playlist_play_rounded,
            tooltip: 'Épisodes suivants',
            metrics: m,
            onPressed: onOpenEpisodes!,
          ),
          SizedBox(width: m.clusterGap),
        ],
        _EmbyIconButton(
          buttonKey: subtitlesButtonKey,
          icon: Icons.closed_caption_rounded,
          tooltip: 'Sous-titres',
          metrics: m,
          onPressed: onToggleSubtitles,
        ),
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          icon: Icons.graphic_eq_rounded,
          tooltip: 'Pistes audio',
          metrics: m,
          onPressed: onOpenAudio,
        ),
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          icon: Icons.speed_rounded,
          // The current rate is the whole point of the control, so it goes in
          // the tooltip rather than making the user open a menu to read it.
          tooltip: 'Vitesse ×${_formatRate(playbackRate)}',
          metrics: m,
          onPressed: onCycleSpeed,
        ),
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          buttonKey: settingsButtonKey,
          icon: Icons.settings_rounded,
          tooltip: 'Réglages',
          metrics: m,
          onPressed: onOpenSettings,
        ),
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          icon: Icons.fullscreen_rounded,
          tooltip: 'Plein écran',
          metrics: m,
          onPressed: onToggleFullscreen,
        ),
      ],
    );
  }

  static String _formatRate(double rate) {
    final asInt = rate.round();
    return rate == asInt ? '$asInt' : rate.toStringAsFixed(2);
  }

  Widget _buildTimes(EmbyChromeMetrics m) {
    final style = TextStyle(
      color: EmbyChromeTheme.time,
      fontSize: m.timeSize,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final hasDuration = duration.inSeconds > 0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(formatPlaybackTime(position.inSeconds), style: style),
        if (hasDuration)
          Text(
            '-${formatPlaybackTime(_remainingSeconds)}'
            '  /  ${formatEndClock(_remainingSeconds)}',
            style: style,
          ),
      ],
    );
  }

  Widget _buildTransport(EmbyChromeMetrics m) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Same rule as the next button: only when there is somewhere to go.
        if (onSkipPrevious != null) ...[
          _EmbyIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Épisode précédent',
            metrics: m,
            onPressed: onSkipPrevious!,
          ),
          SizedBox(width: m.clusterGap + 4),
        ],
        _EmbyIconButton(
          icon: Icons.replay_10_rounded,
          tooltip: 'Reculer de 10 s',
          metrics: m,
          onPressed: onRewind,
        ),
        SizedBox(width: m.clusterGap + 4),
        _EmbyIconButton(
          icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: isPlaying ? 'Pause' : 'Lecture',
          metrics: m,
          size: m.playIconSize,
          onPressed: onPlayPause,
        ),
        SizedBox(width: m.clusterGap + 4),
        _EmbyIconButton(
          icon: Icons.forward_10_rounded,
          tooltip: 'Avancer de 10 s',
          metrics: m,
          onPressed: onForward,
        ),
        // Series only: on a movie, or at the end of a season, there is nothing
        // to go to and the button would sit there doing nothing.
        if (onSkipNext != null) ...[
          SizedBox(width: m.clusterGap + 4),
          _EmbyIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: 'Épisode suivant',
            metrics: m,
            onPressed: onSkipNext!,
          ),
        ],
      ],
    );
  }
}

/// Flat Emby icon button: no chrome, no background — only the icon brightening
/// on hover.
class _EmbyIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final EmbyChromeMetrics metrics;

  /// Overrides [EmbyChromeMetrics.iconSize] (play/pause is larger).
  final double? size;

  /// Anchor for popups that open above this button.
  final GlobalKey? buttonKey;

  const _EmbyIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.metrics,
    this.size,
    this.buttonKey,
  });

  @override
  State<_EmbyIconButton> createState() => _EmbyIconButtonState();
}

class _EmbyIconButtonState extends State<_EmbyIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final iconSize = widget.size ?? m.iconSize;
    // The box grows with an oversized icon so play/pause is not clipped.
    final box = iconSize > m.iconSize ? iconSize + 18 : m.hitSize;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: widget.buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: box,
            height: box,
            child: Icon(
              widget.icon,
              size: iconSize,
              color: _hovered
                  ? EmbyChromeTheme.iconActive
                  : EmbyChromeTheme.icon,
            ),
          ),
        ),
      ),
    );
  }
}

/// Mute toggle plus an always-visible slider, as Emby keeps it.
///
/// Muting has to remember where the volume was: setting it to 0 and back to a
/// hardcoded default would quietly change the user's level.
class _EmbyVolumeControl extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onChanged;
  final EmbyChromeMetrics metrics;

  /// False on narrow chromes, where only the mute button is shown.
  final bool showSlider;

  const _EmbyVolumeControl({
    required this.volume,
    required this.onChanged,
    required this.metrics,
    required this.showSlider,
  });

  @override
  State<_EmbyVolumeControl> createState() => _EmbyVolumeControlState();
}

class _EmbyVolumeControlState extends State<_EmbyVolumeControl> {
  double _lastAudible = 100;

  IconData get _icon {
    if (widget.volume <= 0) return Icons.volume_off_rounded;
    if (widget.volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _toggleMute() {
    if (widget.volume > 0) {
      _lastAudible = widget.volume;
      widget.onChanged(0);
    } else {
      widget.onChanged(_lastAudible <= 0 ? 100 : _lastAudible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _EmbyIconButton(
          icon: _icon,
          tooltip: widget.volume <= 0 ? 'Rétablir le son' : 'Couper le son',
          metrics: m,
          onPressed: _toggleMute,
        ),
        if (widget.showSlider)
          SizedBox(
            width: m.isCompact ? 90 : 130,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: EmbyChromeTheme.progressPlayed,
                inactiveTrackColor: EmbyChromeTheme.progressTrack,
                thumbColor: EmbyChromeTheme.progressPlayed,
                overlayColor: Colors.white24,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: widget.volume.clamp(0, 100),
                max: 100,
                onChanged: (v) {
                  if (v > 0) _lastAudible = v;
                  widget.onChanged(v);
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Emby's skip-intro affordance: a bordered pill above the controls, shown
/// only while an intro chapter is playing.
class _EmbySkipIntroButton extends StatelessWidget {
  final VoidCallback onPressed;
  final EmbyChromeMetrics metrics;

  const _EmbySkipIntroButton({required this.onPressed, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: EmbyChromeTheme.icon, width: 1.4),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Text(
            'Passer l’intro',
            style: TextStyle(
              color: EmbyChromeTheme.iconActive,
              fontSize: metrics.isCompact ? 13 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
