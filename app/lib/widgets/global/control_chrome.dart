import 'dart:ui';
import 'package:flutter/material.dart';
import '../../models/player_layout.dart';
import '../../theme/app_colors.dart';
import 'media_logo_display.dart';

/// Rendering mode for [ControlChrome].
///
/// - [studio]: static preview used on the editing canvas (no playback logic).
/// - [live]: real, interactive control rendered over the video.
enum ControlChromeVariant { studio, live }

const Color _kAccent = Color(0xFF0A84FF);

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

  /// Embedded timeline transport / action buttons (Emby-style).
  final TimelineChromeOptions timelineOptions;
  final VoidCallback? onPlayPause;
  final VoidCallback? onRewind;
  final VoidCallback? onForward;
  final VoidCallback? onSkipPrevious;
  final VoidCallback? onSkipNext;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onToggleSubtitles;
  final VoidCallback? onOpenUpNext;

  /// Anchor for the settings popup when settings is embedded in the timeline.
  final GlobalKey? settingsButtonKey;

  /// Anchor for the subtitles popup when subtitles is embedded in the timeline.
  final GlobalKey? subtitlesButtonKey;

  /// Media title displayed by the [mediaTitle] control.
  final String? mediaTitle;

  /// TMDB title logo URL for the [mediaLogo] control.
  final String? mediaLogoUrl;

  /// Current volume 0.0 -> 100.0 (for volumeSlider).
  final double? volume;

  /// Called when the user drags the volume slider.
  final ValueChanged<double>? onVolumeChanged;

  /// Called when the back button is tapped.
  final VoidCallback? onBack;

  /// Playback rate for [PlayerControlType.playbackSpeed] (e.g. 1.0, 1.5).
  final double? playbackRate;

  /// Current video fit for [PlayerControlType.aspectFit].
  final BoxFit? videoFit;

  /// Frosted-glass blur sigma (0 = no blur, more "liquid").
  final double blurSigma;

  /// Frosted-glass background opacity (lower = more transparent).
  final double glassOpacity;

  /// Apple-style liquid glass (heavier). Off = simple blur + flat tint.
  final bool liquidGlass;

  /// Visual language for this control's chrome. Glass ignores the fields
  /// below; Flat uses [flatAccentColor]/[flatElevation]; Neumorphic uses
  /// [neumorphicIntensity].
  final ControlSkinStyle skin;

  /// Accent colour for the Flat skin.
  final Color flatAccentColor;

  /// Drop-shadow strength for the Flat skin.
  final FlatElevation flatElevation;

  /// Shadow/extrusion depth for the Neumorphic skin, 0.0 -> 1.0.
  final double neumorphicIntensity;

  /// Small muted line shown above [mediaTitle] by [PlayerControlType.episodeTitleBlock]
  /// (e.g. "S2:E1 - Silo - S02E01 - The Engineer WEBDL-2160p Proper").
  final String? episodeInfoLine;

  /// Keeps [PlayerControlType.volumeSlider] permanently expanded instead of
  /// only on hover.
  final bool alwaysExpanded;

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
    this.timelineOptions = const TimelineChromeOptions(showFullscreen: true),
    this.onPlayPause,
    this.onRewind,
    this.onForward,
    this.onSkipPrevious,
    this.onSkipNext,
    this.onOpenSettings,
    this.onToggleSubtitles,
    this.onOpenUpNext,
    this.settingsButtonKey,
    this.subtitlesButtonKey,
    this.mediaTitle,
    this.mediaLogoUrl,
    this.volume,
    this.onVolumeChanged,
    this.onBack,
    this.playbackRate,
    this.videoFit,
    this.blurSigma = kDefaultBlurSigma,
    this.glassOpacity = kDefaultGlassOpacity,
    this.liquidGlass = kDefaultLiquidGlass,
    this.skin = ControlSkinStyle.glass,
    this.flatAccentColor = kDefaultFlatAccentColor,
    this.flatElevation = kDefaultFlatElevation,
    this.neumorphicIntensity = kDefaultNeumorphicIntensity,
    this.episodeInfoLine,
    this.alwaysExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = switch (type) {
      PlayerControlType.progressBar => _buildProgressBar(),
      PlayerControlType.timeline ||
      PlayerControlType.timelineEmby ||
      PlayerControlType.timelineGlassInline => _buildTimelineBar(),
      PlayerControlType.mediaTitle => _buildMediaTitle(),
      PlayerControlType.mediaLogo => _buildMediaLogo(),
      PlayerControlType.episodeTitleBlock => _buildEpisodeTitleBlock(),
      PlayerControlType.chaptersEmby => _buildChaptersEmbyButton(),
      PlayerControlType.mediaInfo => _buildMediaInfoEmbyButton(),
      PlayerControlType.upNext => _buildUpNextButton(),
      PlayerControlType.upNextEmby => _buildUpNextEmbyButton(),
      PlayerControlType.volumeSlider => _buildVolumeSlider(context),
      PlayerControlType.skipIntro => _buildLabeledPill(
          icon: Icons.fast_forward_rounded,
          label: 'Passer l\'intro',
        ),
      PlayerControlType.playbackSpeed => _buildSpeedPill(),
      PlayerControlType.timeRemaining => _buildTimeRemainingPill(),
      PlayerControlType.aspectFit => _buildAspectFitButton(),
      _ => _buildIconButton(),
    };

    if (variant == ControlChromeVariant.studio) {
      child = AbsorbPointer(child: child);
    }

    return child;
  }

  IconData get _icon {
    if (type == PlayerControlType.playPause) {
      return isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded;
    }
    if (type == PlayerControlType.aspectFit) {
      return videoFit == BoxFit.cover
          ? Icons.fit_screen_rounded
          : Icons.crop_free_rounded;
    }
    return type.icon;
  }

  /// Progress-fill colour: the user's chosen accent for Flat, the fixed
  /// system accent otherwise (Neumorphic keeps colour out of the picture).
  Color get _accentColor =>
      skin == ControlSkinStyle.flat ? flatAccentColor : _kAccent;

  double get _pixelSize {
    final emphasis = type == PlayerControlType.playPause ? 1.15 : 1.0;
    return modularControlPixelSize(
      canvasSize,
      sizePercentage,
      emphasis: emphasis,
    );
  }

  void _addTimelineActionBtn(
    List<Widget> out, {
    required IconData icon,
    required bool show,
    required VoidCallback? onTap,
    required double iconSize,
    GlobalKey? key,
  }) {
    if (!show) return;
    if (variant == ControlChromeVariant.live && onTap == null) return;
    Widget btn = _TimelineBarIcon(icon: icon, size: iconSize, onTap: onTap);
    if (key != null) btn = KeyedSubtree(key: key, child: btn);
    out.add(btn);
  }

  /// Studio selection must not change layout size (no thicker border / glow).
  bool get _studioSelected =>
      variant == ControlChromeVariant.studio && selected;

  bool get _liveSelected => variant == ControlChromeVariant.live && selected;

  Widget _glass({required Widget child, required BorderRadius radius}) {
    switch (skin) {
      case ControlSkinStyle.flat:
        return _flatChrome(child: child, radius: radius);
      case ControlSkinStyle.neumorphic:
        return _neumorphicChrome(child: child, radius: radius);
      case ControlSkinStyle.glass:
        if (!liquidGlass) return _simpleGlass(child: child, radius: radius);
        return _liquidGlass(child: child, radius: radius);
    }
  }

  /// Opaque flat surface — no blur, no transparency. Elevation controls the
  /// drop shadow; the accent colour only shows up on the selection ring.
  Widget _flatChrome({required Widget child, required BorderRadius radius}) {
    final selected = _studioSelected || _liveSelected;
    return AnimatedContainer(
      duration: variant == ControlChromeVariant.studio
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: radius,
        border: Border.all(
          color: selected
              ? flatAccentColor.withValues(alpha: 0.9)
              : Colors.white.withOpacity(0.08),
          width: selected ? 1.5 : 1,
        ),
        boxShadow: _flatShadow(flatElevation),
      ),
      child: child,
    );
  }

  /// Soft-extruded surface — dual light/dark shadows, no blur, no user
  /// colour (the tint is derived from the app background so it reads the
  /// same regardless of what's playing behind it).
  Widget _neumorphicChrome({
    required Widget child,
    required BorderRadius radius,
  }) {
    final selected = _studioSelected || _liveSelected;
    return AnimatedContainer(
      duration: variant == ControlChromeVariant.studio
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _neumorphicBase,
        borderRadius: radius,
        border: selected
            ? Border.all(color: _kAccent.withValues(alpha: 0.85), width: 1.5)
            : null,
        boxShadow: _neumorphicShadows(neumorphicIntensity),
      ),
      child: child,
    );
  }

  /// Drop shadow for the Flat skin, shared with [_VolumeSliderButtonState]
  /// so the elevation table only lives in one place.
  static List<BoxShadow> _flatShadow(FlatElevation elevation) {
    return switch (elevation) {
      FlatElevation.none => const <BoxShadow>[],
      FlatElevation.light => [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      FlatElevation.marked => [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
    };
  }

  /// Neutral surface the Neumorphic skin extrudes from — a lightened tint of
  /// the app's own background, not a user-selectable colour.
  static Color get _neumorphicBase =>
      Color.lerp(AppColors.background, Colors.white, 0.14)!;

  /// Dual light/dark extrusion shadows for the Neumorphic skin, shared with
  /// [_VolumeSliderButtonState].
  static List<BoxShadow> _neumorphicShadows(double intensity) {
    final depth =
        intensity.clamp(kMinNeumorphicIntensity, kMaxNeumorphicIntensity);
    if (depth <= 0) return const [];
    final offset = 2 + depth * 4;
    final blur = 4 + depth * 10;
    return [
      BoxShadow(
        color: Colors.white.withOpacity(0.06 + depth * 0.05),
        blurRadius: blur,
        offset: Offset(-offset, -offset),
      ),
      BoxShadow(
        color: Colors.black.withOpacity(0.35 + depth * 0.2),
        blurRadius: blur,
        offset: Offset(offset, offset),
      ),
    ];
  }

  /// Lightweight path: blur + flat tint only (one BackdropFilter, no extras).
  Widget _simpleGlass({required Widget child, required BorderRadius radius}) {
    final borderOpacity = (glassOpacity * 1.5 + 0.05).clamp(0.05, 0.4);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: AnimatedContainer(
          duration: variant == ControlChromeVariant.studio
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(glassOpacity),
            borderRadius: radius,
            border: Border.all(
              color: (_studioSelected || _liveSelected)
                  ? _kAccent.withValues(alpha: 0.85)
                  : Colors.white.withOpacity(borderOpacity),
              width: (_studioSelected || _liveSelected) ? 1.5 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  /// Heavier Apple-style path: saturation boost, sheen, rim, shadow.
  Widget _liquidGlass({required Widget child, required BorderRadius radius}) {
    final double o = glassOpacity;

    // Apple-style "liquid glass": the background is blurred AND its colours are
    // boosted (saturation + a touch of brightness) so the glass looks alive and
    // refractive rather than a flat frosted panel.
    final backdrop = ImageFilter.compose(
      outer: ColorFilter.matrix(_liquidGlassMatrix(saturation: 1.6, brightness: 1.06)),
      inner: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
    );

    // Directional glossy sheen: brighter at the top-left, fading down.
    final sheen = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity((o * 2.0 + 0.02).clamp(0.03, 0.55)),
        Colors.white.withOpacity((o * 0.6).clamp(0.0, 0.25)),
      ],
      stops: const [0.0, 1.0],
    );

    // Top specular highlight — the tell-tale glossy edge of Apple's glass.
    final specular = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.center,
      colors: [
        Colors.white.withOpacity((o * 2.5 + 0.12).clamp(0.12, 0.5)),
        Colors.white.withOpacity(0.0),
      ],
    );

    // Gradient rim: bright light-catching edge at the top-left, faint elsewhere.
    final rim = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _studioSelected
          ? [
              _kAccent.withOpacity(0.85),
              _kAccent.withOpacity(0.35),
            ]
          : [
              Colors.white.withOpacity((o * 3 + 0.30).clamp(0.25, 0.75)),
              Colors.white.withOpacity((o + 0.02).clamp(0.03, 0.2)),
            ],
    );

    Widget glass = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: backdrop,
        child: Container(
          decoration: BoxDecoration(gradient: sheen, borderRadius: radius),
          foregroundDecoration:
              BoxDecoration(gradient: specular, borderRadius: radius),
          child: child,
        ),
      ),
    );

    return AnimatedContainer(
      duration: variant == ControlChromeVariant.studio
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(1.2), // rim thickness
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: _liveSelected ? null : rim,
        border: _liveSelected
            ? Border.all(color: _kAccent.withValues(alpha: 0.85), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: glass,
    );
  }

  /// Colour matrix that boosts saturation and brightness of whatever is behind
  /// the glass, mimicking the light-bending look of Apple's Liquid Glass.
  static List<double> _liquidGlassMatrix({
    required double saturation,
    double brightness = 1.0,
  }) {
    const lumR = 0.213, lumG = 0.715, lumB = 0.072;
    final s = saturation;
    final sr = (1 - s) * lumR;
    final sg = (1 - s) * lumG;
    final sb = (1 - s) * lumB;
    final b = (brightness - 1.0) * 255.0;
    return [
      sr + s, sg, sb, 0, b,
      sr, sg + s, sb, 0, b,
      sr, sg, sb + s, 0, b,
      0, 0, 0, 1, 0,
    ];
  }

  Widget _buildIconButton() {
    final double pixelSize = _pixelSize;
    final double diameter = pixelSize * kControlChromePaddingFactor;
    final icon = type == PlayerControlType.playPause
        ? AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              _icon,
              key: ValueKey(isPlaying),
              color: Colors.white,
              size: pixelSize,
            ),
          )
        : Icon(_icon, color: Colors.white, size: pixelSize);

    return _glass(
      radius: BorderRadius.circular(diameter / 2),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Center(child: icon),
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
                      color: _accentColor,
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
    if (type == PlayerControlType.timelineEmby ||
        timelineOptions.visualStyle == TimelineVisualStyle.emby) {
      return _buildEmbyTimelineBar();
    }
    if (type == PlayerControlType.timelineGlassInline) {
      return _buildGlassInlineTimelineBar();
    }
    switch (timelineOptions.visualStyle) {
      case TimelineVisualStyle.flat:
        return _buildFlatTimelineBar();
      case TimelineVisualStyle.neumorphic:
        return _buildNeumorphicTimelineBar();
      case TimelineVisualStyle.glass:
      case TimelineVisualStyle.emby:
        return _buildGlassTimelineBar();
    }
  }

  Widget _seekableTimelineTrack(Widget track) {
    if (onSeekFraction == null) return track;
    return _TimelineSeekable(
      onSeekFraction: onSeekFraction!,
      onPlayPause: onPlayPause,
      isPlaying: isPlaying,
      child: track,
    );
  }

  Widget _buildGlassTimelineBar() => _buildPillTimelineBar(wrap: _glass);

  Widget _buildFlatTimelineBar() => _buildPillTimelineBar(wrap: _flatChrome);

  Widget _buildNeumorphicTimelineBar() =>
      _buildPillTimelineBar(wrap: _neumorphicChrome);

  /// Shared layout for the "pill" timeline shape (time labels above the
  /// track, transport + action buttons below) — only the chrome [wrap]
  /// differs between the Glass, Flat and Neumorphic variants.
  Widget _buildPillTimelineBar({
    required Widget Function({required Widget child, required BorderRadius radius})
        wrap,
  }) {
    final opts = timelineOptions;
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

    final iconSize = (height * 0.72).clamp(16.0, 26.0);

    final barTrackHeight = height * 0.55;
    final barTrack = SizedBox(
      height: barTrackHeight,
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
                color: _accentColor,
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

    final bar = _seekableTimelineTrack(barTrack);

    void addBtn(List<Widget> out, IconData icon, bool show, VoidCallback? onTap) {
      if (!show) return;
      if (variant == ControlChromeVariant.live && onTap == null) return;
      out.add(_TimelineBarIcon(icon: icon, size: iconSize, onTap: onTap));
    }

    final transportButtons = <Widget>[];
    addBtn(transportButtons, Icons.skip_previous, opts.showSkipPrevious, onSkipPrevious);
    addBtn(transportButtons, Icons.replay_10, opts.showRewind, onRewind);
    addBtn(
      transportButtons,
      isPlaying ? Icons.pause : Icons.play_arrow,
      opts.showPlayPause,
      onPlayPause,
    );
    addBtn(transportButtons, Icons.forward_10, opts.showForward, onForward);
    addBtn(transportButtons, Icons.skip_next, opts.showSkipNext, onSkipNext);

    final actionButtons = <Widget>[];
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.settings,
      show: opts.showSettings,
      onTap: onOpenSettings,
      iconSize: iconSize,
      key: settingsButtonKey,
    );
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.subtitles,
      show: opts.showSubtitles,
      onTap: onToggleSubtitles,
      iconSize: iconSize,
      key: subtitlesButtonKey,
    );
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.playlist_play_rounded,
      show: opts.showUpNext,
      onTap: onOpenUpNext,
      iconSize: iconSize,
    );

    Widget? fullscreenBtn;
    if (opts.showFullscreen &&
        (variant != ControlChromeVariant.live || onToggleFullscreen != null)) {
      fullscreenBtn = _TimelineBarIcon(
        icon: Icons.fullscreen,
        size: iconSize,
        onTap: onToggleFullscreen,
      );
    }

    final hasBottomRow =
        transportButtons.isNotEmpty || actionButtons.isNotEmpty;
    const rowGap = 6.0;
    const hPad = 18.0;
    const vPad = 8.0;

    final textLineHeight = (height * 0.45).clamp(10.0, 16.0) * 1.25;
    final topBlockHeight = textLineHeight + 4 + barTrackHeight;
    final bottomBlockHeight = hasBottomRow ? rowGap + iconSize + 4 : 0.0;
    final estimatedHeight = topBlockHeight + bottomBlockHeight + vPad * 2;

    return wrap(
      radius: BorderRadius.circular(estimatedHeight / 2 + 6),
      child: SizedBox(
        width: canvasSize.width * widthPercentage.clamp(0.3, 1.0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(Duration(seconds: current)),
                              style: timeStyle,
                            ),
                            Flexible(
                              child: Text(
                                '-${_formatDuration(Duration(seconds: remaining))} / ${_formatEndTime(remaining)}',
                                style: timeStyle.copyWith(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize:
                                      (height * 0.38).clamp(9.0, 13.0),
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        bar,
                      ],
                    ),
                  ),
                  if (fullscreenBtn != null) ...[
                    const SizedBox(width: 8),
                    fullscreenBtn,
                  ],
                ],
              ),
              if (hasBottomRow) ...[
                const SizedBox(height: rowGap),
                Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: transportButtons,
                    ),
                    const Spacer(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: actionButtons,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Glass pill with transport on the left, actions on the right, slim bar center.
  Widget _buildGlassInlineTimelineBar() {
    final opts = timelineOptions;
    final double height = (_pixelSize * 0.45).clamp(12.0, 36.0);
    final totalSec = duration?.inSeconds ?? 3600;
    final current = (currentSeconds ?? 0).clamp(0, totalSec);
    final remaining = totalSec - current;
    final frac = totalSec > 0 ? current / totalSec : 0.0;

    final timeStyle = TextStyle(
      color: Colors.white.withOpacity(0.85),
      fontSize: (height * 0.42).clamp(9.0, 13.0),
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final iconSize = (height * 0.68).clamp(14.0, 22.0);
    const barThickness = 3.0;
    final barTrackHeight = height * 0.42;

    final barTrack = SizedBox(
      width: double.infinity,
      height: barTrackHeight,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Container(
            width: double.infinity,
            height: barThickness,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          FractionallySizedBox(
            widthFactor: frac.clamp(0.0, 1.0),
            child: Container(
              height: barThickness,
              decoration: BoxDecoration(
                color: _kAccent,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
          Align(
            alignment: Alignment(frac.clamp(0.0, 1.0) * 2 - 1, 0),
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );

    final bar = _seekableTimelineTrack(barTrack);

    void addBtn(List<Widget> out, IconData icon, bool show, VoidCallback? onTap) {
      if (!show) return;
      if (variant == ControlChromeVariant.live && onTap == null) return;
      out.add(_TimelineBarIcon(icon: icon, size: iconSize, onTap: onTap));
    }

    final transportButtons = <Widget>[];
    addBtn(transportButtons, Icons.skip_previous, opts.showSkipPrevious, onSkipPrevious);
    addBtn(transportButtons, Icons.replay_10, opts.showRewind, onRewind);
    addBtn(
      transportButtons,
      isPlaying ? Icons.pause : Icons.play_arrow,
      opts.showPlayPause,
      onPlayPause,
    );
    addBtn(transportButtons, Icons.forward_10, opts.showForward, onForward);
    addBtn(transportButtons, Icons.skip_next, opts.showSkipNext, onSkipNext);

    final actionButtons = <Widget>[];
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.settings,
      show: opts.showSettings,
      onTap: onOpenSettings,
      iconSize: iconSize,
      key: settingsButtonKey,
    );
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.subtitles,
      show: opts.showSubtitles,
      onTap: onToggleSubtitles,
      iconSize: iconSize,
      key: subtitlesButtonKey,
    );
    _addTimelineActionBtn(
      actionButtons,
      icon: Icons.playlist_play_rounded,
      show: opts.showUpNext,
      onTap: onOpenUpNext,
      iconSize: iconSize,
    );
    addBtn(actionButtons, Icons.fullscreen, opts.showFullscreen, onToggleFullscreen);

    const hPad = 12.0;
    const vPad = 5.0;
    const sideGap = 8.0;
    const timeGap = 8.0;

    final blockHeight = iconSize + 4;
    final estimatedHeight = blockHeight + vPad * 2;

    Widget buttonRow(List<Widget> buttons) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            buttons[i],
          ],
        ],
      );
    }

    return _glass(
      radius: BorderRadius.circular(estimatedHeight / 2 + 6),
      child: SizedBox(
        width: double.infinity,
        height: estimatedHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (transportButtons.isNotEmpty) ...[
                buttonRow(transportButtons),
                const SizedBox(width: sideGap),
              ],
              Text(
                _formatDuration(Duration(seconds: current)),
                style: timeStyle,
              ),
              const SizedBox(width: timeGap),
              Expanded(child: bar),
              const SizedBox(width: timeGap),
              Text(
                '-${_formatDuration(Duration(seconds: remaining))} / ${_formatEndTime(remaining)}',
                style: timeStyle.copyWith(
                  color: Colors.white.withOpacity(0.65),
                  fontSize: (height * 0.36).clamp(8.0, 12.0),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              if (actionButtons.isNotEmpty) ...[
                const SizedBox(width: sideGap),
                buttonRow(actionButtons),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmbyTimelineBar() {
    final opts = timelineOptions;
    final double scale = (_pixelSize * 0.5).clamp(14.0, 40.0);
    final totalSec = duration?.inSeconds ?? 3600;
    final current = (currentSeconds ?? 0).clamp(0, totalSec);
    final remaining = totalSec - current;
    final frac = totalSec > 0 ? current / totalSec : 0.0;

    final timeStyle = TextStyle(
      color: Colors.white.withOpacity(0.92),
      fontSize: (scale * 0.42).clamp(11.0, 15.0),
      fontWeight: FontWeight.w400,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final iconSize = (scale * 0.78).clamp(20.0, 28.0);
    const lineHeight = 2.0;

    final barTrack = SizedBox(
      width: double.infinity,
      height: 14,
      child: Center(
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              width: double.infinity,
              height: lineHeight,
              color: Colors.white.withOpacity(0.35),
            ),
            FractionallySizedBox(
              widthFactor: frac.clamp(0.0, 1.0),
              child: Container(
                height: lineHeight,
                color: Colors.white,
              ),
            ),
            Align(
              alignment: Alignment(frac.clamp(0.0, 1.0) * 2 - 1, 0),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final bar = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: _seekableTimelineTrack(barTrack),
    );

    void addEmbyBtn(List<Widget> out, IconData icon, bool show, VoidCallback? onTap) {
      if (!show) return;
      if (variant == ControlChromeVariant.live && onTap == null) return;
      out.add(_EmbyTimelineIcon(icon: icon, size: iconSize, onTap: onTap));
    }

    final transportButtons = <Widget>[];
    addEmbyBtn(transportButtons, Icons.skip_previous, opts.showSkipPrevious, onSkipPrevious);
    addEmbyBtn(transportButtons, Icons.replay_10, opts.showRewind, onRewind);
    addEmbyBtn(
      transportButtons,
      isPlaying ? Icons.pause : Icons.play_arrow,
      opts.showPlayPause,
      onPlayPause,
    );
    addEmbyBtn(transportButtons, Icons.forward_10, opts.showForward, onForward);
    addEmbyBtn(transportButtons, Icons.skip_next, opts.showSkipNext, onSkipNext);

    final utilityButtons = <Widget>[];
    void addEmbyActionBtn(
      IconData icon,
      bool show,
      VoidCallback? onTap, {
      GlobalKey? key,
    }) {
      if (!show) return;
      if (variant == ControlChromeVariant.live && onTap == null) return;
      Widget btn = _EmbyTimelineIcon(icon: icon, size: iconSize, onTap: onTap);
      if (key != null) btn = KeyedSubtree(key: key, child: btn);
      utilityButtons.add(btn);
    }

    addEmbyActionBtn(
      Icons.closed_caption_outlined,
      opts.showSubtitles,
      onToggleSubtitles,
      key: subtitlesButtonKey,
    );
    addEmbyActionBtn(
      Icons.settings_outlined,
      opts.showSettings,
      onOpenSettings,
      key: settingsButtonKey,
    );
    addEmbyActionBtn(
      Icons.view_list_rounded,
      opts.showUpNext,
      onOpenUpNext,
    );
    addEmbyBtn(
      utilityButtons,
      Icons.fullscreen,
      opts.showFullscreen,
      onToggleFullscreen,
    );

    Widget utilityRow(List<Widget> buttons) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            buttons[i],
          ],
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (utilityButtons.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerRight,
                child: utilityRow(utilityButtons),
              ),
              const SizedBox(height: 10),
            ],
            bar,
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  _formatDuration(Duration(seconds: current)),
                  style: timeStyle,
                ),
                const Spacer(),
                Text(
                  '-${_formatDuration(Duration(seconds: remaining))} / ${_formatEndTime(remaining)}',
                  style: timeStyle.copyWith(
                    color: Colors.white.withOpacity(0.75),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                ),
              ],
            ),
            if (transportButtons.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: utilityRow(transportButtons),
              ),
            ],
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

  /// Two-line Emby-style title block: a small muted episode/release line
  /// above a bold show-title line. No chrome background, like [_buildMediaTitle].
  Widget _buildEpisodeTitleBlock() {
    final double height = (_pixelSize * 1.7).clamp(40.0, 76.0);
    final infoLine = episodeInfoLine;
    return SizedBox(
      height: height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (infoLine != null && infoLine.isNotEmpty) ...[
            Text(
              infoLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: (height * 0.22).clamp(11.0, 15.0),
                fontWeight: FontWeight.w400,
              ),
            ),
            SizedBox(height: height * 0.06),
          ],
          Text(
            mediaTitle ?? 'Titre du média',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: (height * 0.34).clamp(16.0, 26.0),
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  /// Emby-style plain text link (icon + label, no chrome background).
  Widget _buildEmbyTextLink({required IconData icon, required String label}) {
    final double height = (_pixelSize * 1.2).clamp(28.0, 40.0);
    final double iconSize = (_pixelSize * 0.75).clamp(18.0, 24.0);
    final double fontSize = (_pixelSize * 0.36).clamp(12.0, 15.0);

    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white.withOpacity(0.92), size: iconSize),
          SizedBox(width: height * 0.22),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.92),
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChaptersEmbyButton() =>
      _buildEmbyTextLink(icon: Icons.list_alt_rounded, label: 'Chapitres');

  Widget _buildMediaInfoEmbyButton() =>
      _buildEmbyTextLink(icon: Icons.info_outline_rounded, label: 'Info');

  Widget _buildLabeledPill({required IconData icon, required String label}) {
    final double height = (_pixelSize * 1.15).clamp(32.0, 44.0);
    final double iconSize = (_pixelSize * 0.75).clamp(16.0, 20.0);
    final double fontSize = (_pixelSize * 0.36).clamp(11.0, 13.5);
    return _glass(
      radius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: height * 0.35),
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: iconSize),
              SizedBox(width: height * 0.16),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.95),
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedPill() {
    final rate = playbackRate ?? 1.0;
    final label = rate % 1 == 0 ? '${rate.toInt()}×' : '${rate}×';
    final double height = (_pixelSize * 1.15).clamp(30.0, 42.0);
    final double fontSize = (_pixelSize * 0.4).clamp(12.0, 15.0);
    return _glass(
      radius: BorderRadius.circular(12),
      child: SizedBox(
        height: height,
        width: height * 2.2,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.95),
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeRemainingPill() {
    final total = duration?.inSeconds ?? 0;
    final current = (currentSeconds ?? 0).clamp(0, total > 0 ? total : 0);
    final remaining = total > 0 ? (total - current).clamp(0, total) : 0;
    final label = total > 0 ? '-${_formatClock(remaining)}' : '--:--';
    final double height = (_pixelSize * 1.15).clamp(30.0, 42.0);
    final double fontSize = (_pixelSize * 0.38).clamp(11.0, 14.0);
    return _glass(
      radius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: height * 0.32),
        child: SizedBox(
          height: height,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: -0.1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAspectFitButton() {
    final double pixelSize = _pixelSize;
    final double diameter = pixelSize * kControlChromePaddingFactor;
    return _glass(
      radius: BorderRadius.circular(diameter / 2),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Center(
          child: Icon(_icon, color: Colors.white, size: pixelSize),
        ),
      ),
    );
  }

  String _formatClock(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildUpNextButton() {
    final double height =
        (_pixelSize * kControlChromePaddingFactor).clamp(36.0, 52.0);
    final double iconSize = (_pixelSize * 0.85).clamp(16.0, 22.0);
    final double fontSize = (_pixelSize * 0.38).clamp(11.0, 14.0);
    final radius = BorderRadius.circular(height / 2);

    return _glass(
      radius: radius,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: height * 0.38),
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_play_rounded, color: Colors.white, size: iconSize),
              SizedBox(width: height * 0.18),
              Text(
                'À suivre',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.95),
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUpNextEmbyButton() =>
      _buildEmbyTextLink(icon: Icons.view_list_rounded, label: 'À suivre');

  Widget _buildMediaLogo() {
    final double height =
        (_pixelSize * kControlChromePaddingFactor).clamp(36.0, 100.0);
    final double width = canvasSize.width * widthPercentage.clamp(0.15, 0.55);
    return SizedBox(
      width: width,
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: MediaLogoDisplay(
          title: mediaTitle ?? 'Titre du média',
          logoUrl: mediaLogoUrl,
          maxHeight: height,
          maxWidth: width,
          textStyle: TextStyle(
            fontSize: (height * 0.38).clamp(14.0, 36.0),
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeSlider(BuildContext context) {
    final double height = (_pixelSize * 0.5).clamp(16.0, 40.0);
    final double width = canvasSize.width * widthPercentage.clamp(0.05, 0.5);
    return _VolumeSliderButton(
      height: height,
      width: width,
      forceExpanded: variant == ControlChromeVariant.studio || alwaysExpanded,
      volume: volume,
      onVolumeChanged: onVolumeChanged,
      blurSigma: blurSigma,
      glassOpacity: glassOpacity,
      liquidGlass: liquidGlass,
      skin: skin,
      flatAccentColor: flatAccentColor,
      flatElevation: flatElevation,
      neumorphicIntensity: neumorphicIntensity,
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
  final double blurSigma;
  final double glassOpacity;
  final bool liquidGlass;
  final ControlSkinStyle skin;
  final Color flatAccentColor;
  final FlatElevation flatElevation;
  final double neumorphicIntensity;

  const _VolumeSliderButton({
    required this.height,
    required this.width,
    this.forceExpanded = false,
    this.volume,
    this.onVolumeChanged,
    this.blurSigma = kDefaultBlurSigma,
    this.glassOpacity = kDefaultGlassOpacity,
    this.liquidGlass = kDefaultLiquidGlass,
    this.skin = ControlSkinStyle.glass,
    this.flatAccentColor = kDefaultFlatAccentColor,
    this.flatElevation = kDefaultFlatElevation,
    this.neumorphicIntensity = kDefaultNeumorphicIntensity,
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

    final radius = BorderRadius.circular(widget.height / 2 + 6);
    final o = widget.glassOpacity;

    if (widget.skin == ControlSkinStyle.flat) {
      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          width: _expanded ? widget.width : widget.height,
          height: widget.height,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: radius,
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: ControlChrome._flatShadow(widget.flatElevation),
          ),
          child: _volumeRow(vol, iconSize),
        ),
      );
    }

    if (widget.skin == ControlSkinStyle.neumorphic) {
      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          width: _expanded ? widget.width : widget.height,
          height: widget.height,
          decoration: BoxDecoration(
            color: ControlChrome._neumorphicBase,
            borderRadius: radius,
            boxShadow:
                ControlChrome._neumorphicShadows(widget.neumorphicIntensity),
          ),
          child: _volumeRow(vol, iconSize),
        ),
      );
    }

    if (!widget.liquidGlass) {
      final fillOpacity = (o + 0.06).clamp(0.05, 0.55);
      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: widget.blurSigma,
              sigmaY: widget.blurSigma,
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: _expanded ? widget.width : widget.height,
              height: widget.height,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(fillOpacity),
                borderRadius: radius,
              ),
              child: _volumeRow(vol, iconSize),
            ),
          ),
        ),
      );
    }

    // Match the liquid look of the other controls.
    final backdrop = ImageFilter.compose(
      outer: ColorFilter.matrix(
        ControlChrome._liquidGlassMatrix(saturation: 1.6, brightness: 1.06),
      ),
      inner: ImageFilter.blur(sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
    );
    final sheen = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity((o * 2.0 + 0.08).clamp(0.08, 0.55)),
        Colors.white.withOpacity((o + 0.02).clamp(0.03, 0.3)),
      ],
    );
    final rim = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity((o * 3 + 0.30).clamp(0.25, 0.75)),
        Colors.white.withOpacity((o + 0.02).clamp(0.03, 0.2)),
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(gradient: rim, borderRadius: radius),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: backdrop,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: _expanded ? widget.width : widget.height,
              height: widget.height,
              decoration: BoxDecoration(
                gradient: sheen,
                borderRadius: radius,
              ),
              child: _volumeRow(vol, iconSize),
            ),
          ),
        ),
      ),
    );
  }

  Widget _volumeRow(double vol, double iconSize) {
    return Row(
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
                      activeTrackColor: const Color(0xFF0A84FF),
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
    );
  }
}

/// Compact icon button embedded in the timeline bar.
class _TimelineBarIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;

  const _TimelineBarIcon({
    required this.icon,
    required this.size,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final side = size + 4;
    return SizedBox(
      width: side,
      height: side,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size),
          child: Center(
            child: Icon(
              icon,
              color: Colors.white.withOpacity(0.9),
              size: size,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps a timeline track so that:
/// - a tap seeks to the tapped position
/// - a horizontal drag seeks continuously
/// - the player pauses at drag start and resumes at drag end if it was playing.
class _TimelineSeekable extends StatefulWidget {
  final Widget child;
  final ValueChanged<double> onSeekFraction;
  final VoidCallback? onPlayPause;
  final bool isPlaying;

  const _TimelineSeekable({
    required this.child,
    required this.onSeekFraction,
    this.onPlayPause,
    this.isPlaying = false,
  });

  @override
  State<_TimelineSeekable> createState() => _TimelineSeekableState();
}

class _TimelineSeekableState extends State<_TimelineSeekable> {
  bool _wasPlaying = false;

  void _emit(BuildContext context, Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return;
    final fraction = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
    widget.onSeekFraction(fraction);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (d) => _emit(context, d.localPosition),
      onHorizontalDragStart: (d) {
        _wasPlaying = widget.isPlaying;
        if (_wasPlaying) widget.onPlayPause?.call();
        _emit(context, d.localPosition);
      },
      onHorizontalDragUpdate: (d) => _emit(context, d.localPosition),
      onHorizontalDragEnd: (_) {
        if (_wasPlaying) widget.onPlayPause?.call();
        _wasPlaying = false;
      },
      onHorizontalDragCancel: () {
        if (_wasPlaying) widget.onPlayPause?.call();
        _wasPlaying = false;
      },
      child: widget.child,
    );
  }
}

/// Flat white icon for the Emby-style timeline (no background pill).
class _EmbyTimelineIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;

  const _EmbyTimelineIcon({
    required this.icon,
    required this.size,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            color: Colors.white.withOpacity(0.92),
            size: size,
          ),
        ),
      ),
    );
  }
}
