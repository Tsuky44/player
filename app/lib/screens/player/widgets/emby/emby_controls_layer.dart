
import 'package:flutter/material.dart';

import '../../../../desktop_window.dart';
import '../../../../theme/app_colors.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../tv/tv_focus_rows.dart';
import '../../../../utils/format.dart';
import '../../../../widgets/global/app_network_image.dart';
import '../avoid_cutouts.dart';
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
/// scrubber, compact stacks them so nothing collides at phone widths. A
/// television gets its own, laid out like Crunchyroll's — see
/// [_buildTvChrome].
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

  /// What left and right do on the focused scrubber, on a television. Default
  /// to [onRewind] / [onForward]; the player passes steps that chain while
  /// the key is held instead of seeking on each one.
  final VoidCallback? onScrubStepBack;
  final VoidCallback? onScrubStepForward;

  /// Television only: the remote moved between the chrome's controls. The
  /// player uses it to hold the chrome on screen while someone is using it.
  final VoidCallback? onRemoteNavigate;

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

  // --- Television ---------------------------------------------------------

  /// How big the chrome is drawn, as a factor.
  ///
  /// 1 everywhere except on an iPhone, where the same widget reads slightly
  /// larger than it does on Android at the same width. Only what is drawn
  /// shrinks — the touch targets do not, see
  /// [EmbyChromeMetrics.scaledBy]. Passed in rather than read from the
  /// platform, for the same reason [showVolume] is: the Studio renders this
  /// chrome away from any device.
  final double scale;

  /// Whether the top bar carries a volume control.
  ///
  /// False on a phone: the handset has volume keys under the fingers already
  /// holding it, and a second control for the same thing costs a slot in a row
  /// that is short of them. Kept on a computer, where the only volume within
  /// reach is the one on screen.
  final bool showVolume;

  /// Driven by a remote rather than a mouse or a finger.
  ///
  /// The chrome takes its television arrangement ([_buildTvChrome]), without
  /// what a remote has no use for: the volume control (a set has its own on
  /// its own remote), the brightness bar (a television's backlight is not this
  /// app's to drive), the fullscreen toggle (there is no window) and the speed
  /// button (the rate is in the settings menu). The scrubber becomes a focus
  /// stop that seeks with left and right.
  final bool isTv;

  /// Where the remote lands when it enters the control bar. Play/pause is the
  /// button a hand reaches for first, and every other control is one or two
  /// presses from it.
  final FocusNode? playPauseFocusNode;

  /// The scrubber's node. On a television the remote lands here when it
  /// brought the HUD up with a seek, so left and right go on meaning "seek" —
  /// only now with an outline saying which control is answering.
  final FocusNode? progressFocusNode;

  /// Where the screen's own hardware sits — a camera bubble, a notch — as
  /// rectangles in the window's coordinates, from [DisplayCutouts].
  ///
  /// Rectangles rather than margins, and applied row by row rather than to the
  /// chrome as a whole: a bubble halfway down the left edge has to move the
  /// brightness bar and nothing else. Padding the layer would have moved the
  /// title, the scrubber and every button with it, which is the interface
  /// stepping aside for something that was in the way of one control.
  ///
  /// The scrims are never moved: a gradient that stops short of the camera
  /// reads as a rendering bug, while a button that stops short of it reads as
  /// intent.
  ///
  /// Empty for anything rendering this chrome away from a screen edge — the
  /// Studio preview, a windowed desktop — which is why it is passed in rather
  /// than read from the ambient [MediaQuery].
  final List<Rect> cutouts;

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
    this.onScrubStepBack,
    this.onScrubStepForward,
    this.onRemoteNavigate,
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
    this.isTv = false,
    this.playPauseFocusNode,
    this.progressFocusNode,
    this.cutouts = const <Rect>[],
    this.showVolume = true,
    this.scale = 1,
  });

  /// The empty strip at the bottom of the top bar, and the one at the top of
  /// the bottom bar.
  ///
  /// Both are pure scrim: gradient, nothing drawn in them, nothing in them that
  /// can take a touch. They belong to the brightness bar as much as to the bars
  /// they pad — and on a phone held sideways they have to, because the bottom
  /// bar alone is more than half the height of the screen and what is left
  /// between the two is not enough to put a control in.
  static const double _topBarTail = 28;
  static const double _bottomBarLead = 60;

  /// Moves one row of the chrome clear of a camera bubble, if the bubble is
  /// actually on it. Everything else stays exactly where it was.
  Widget _dodgeCutouts(Widget child) => cutouts.isEmpty
      ? child
      : AvoidCutouts(cutouts: cutouts, child: child);

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
        final m = EmbyChromeTheme.metricsFor(width, scale: scale, tv: isTv);
        if (isTv) return _buildTvChrome(m);
        final hasBrightness =
            brightness != null && onBrightnessChanged != null;
        // Not a Stack.
        //
        // The brightness bar shares the right edge with the utilities cluster
        // — subtitles, audio, speed, settings, fullscreen — and in a Stack the
        // two only stayed apart by arithmetic: guess the height of the top bar,
        // guess the height of the bottom one, hope the bar fits between them.
        // Where they did overlap, the buttons are hit-tested first, so the
        // lower part of the bar quietly stopped answering — it looked like a
        // control that only worked at the top.
        //
        // This lays the two bars out first, measures them, and gives the bar
        // the band that is actually left. It cannot overlap either of them,
        // and the band being known means the whole of it can catch a finger.
        return CustomMultiChildLayout(
          delegate: _EmbyChromeLayout(
            topLead: _topBarTail,
            // The skip-intro button sits in that strip when there is one, and
            // it is a button: the bar has to stay off it.
            bottomLead: onSkipIntro == null ? _bottomBarLead : 0,
          ),
          children: [
            LayoutId(
              id: _EmbyChromeLayout.top,
              child: _fadeWithChrome(_buildTop(m, width)),
            ),
            // It rides the same fade as the chrome: a bar floating alone over
            // a film nobody is touching is exactly the clutter the auto-hide
            // exists to remove.
            if (hasBrightness)
              LayoutId(
                id: _EmbyChromeLayout.brightness,
                // A full-width row holding one right-aligned control, rather
                // than a box pinned to the right edge: that is the shape the
                // cutout dodge reasons about, and it is what lets a camera on
                // this edge push the bar in without moving anything else.
                child: _dodgeCutouts(
                  Padding(
                    padding: EdgeInsets.only(right: m.gutter - 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _fadeWithChrome(
                          EmbyBrightnessSlider(
                            value: brightness!,
                            onChanged: onBrightnessChanged!,
                            onDraggingChanged: onBrightnessDraggingChanged,
                            metrics: m,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            LayoutId(
              id: _EmbyChromeLayout.bottom,
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
                      padding: EdgeInsets.fromLTRB(
                        m.gutter,
                        0,
                        m.gutter,
                        14,
                      ),
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

  // --- Television ---------------------------------------------------------

  /// The television arrangement, after Crunchyroll's: the title and the track
  /// menus along the top, the transport in the middle of the picture, the
  /// timeline along the bottom.
  ///
  /// Three rows, walked in straight lines ([TvFocusRows]): left and right stay
  /// on the row, up and down go to the next one — onto play/pause in the
  /// middle, onto the timeline at the bottom, onto the nearest button at the
  /// top.
  Widget _buildTvChrome(EmbyChromeMetrics m) {
    return TvFocusRows(
      onNavigate: onRemoteNavigate,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A soft shade behind the middle row, so white icons still read over
          // a bright scene. Part of the fade like everything else.
          Positioned.fill(
            child: IgnorePointer(
              child: _fadeWithChrome(
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.6,
                      colors: [Color(0x59000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _fadeWithChrome(_buildTvTop(m)),
          ),
          Positioned.fill(
            child: Center(
              child: _fadeWithChrome(
                TvFocusRow(
                  preferredFocus: playPauseFocusNode,
                  child: _buildTransport(m),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Outside the fade, as on the other chromes: the offer is
                // time-limited and must not expire behind a hidden chrome.
                if (onSkipIntro != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(m.gutter, 0, m.gutter, 14),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TvFocusRow(
                        child: _EmbySkipIntroButton(
                          onPressed: onSkipIntro!,
                          metrics: m,
                        ),
                      ),
                    ),
                  ),
                _fadeWithChrome(_buildTvBottom(m)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvTop(EmbyChromeMetrics m) {
    return Container(
      padding: EdgeInsets.fromLTRB(m.gutter, m.topInset, m.gutter, _topBarTail),
      decoration: const BoxDecoration(gradient: EmbyChromeTheme.topScrim),
      child: TvFocusRow(
        child: Row(
          children: [
            _EmbyIconButton(
              key: const ValueKey('emby-back'),
              icon: Icons.arrow_back_ios_new_rounded,
              tooltip: 'Retour',
              metrics: m,
              isTv: true,
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
            Flexible(child: _buildBrand(m)),
            const SizedBox(width: 24),
            _buildUtilities(m),
          ],
        ),
      ),
    );
  }

  Widget _buildTvBottom(EmbyChromeMetrics m) {
    return Stack(
      children: [
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: EmbyChromeTheme.bottomScrim),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            m.gutter,
            _bottomBarLead,
            m.gutter,
            m.bottomInset,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitleBlock(m),
              const SizedBox(height: 10),
              TvFocusRow(
                preferredFocus: progressFocusNode,
                child: KeyedSubtree(
                  key: timelineAnchorKey,
                  child: EmbyProgressBar(
                    progress: _progressFraction,
                    buffered: buffered,
                    duration: duration,
                    chapterMarks: chapterMarks,
                    metrics: m,
                    onSeek: onSeekFraction,
                    onScrubbingChanged: onScrubbingChanged,
                    focusable: true,
                    onStepBack: onScrubStepBack ?? onRewind,
                    onStepForward: onScrubStepForward ?? onForward,
                    onSelect: onPlayPause,
                    focusNode: progressFocusNode,
                  ),
                ),
              ),
              _buildTimes(m),
            ],
          ),
        ),
      ],
    );
  }

  /// Wraps a part of the chrome in the show/hide fade — and takes it out of
  /// hit-testing while it is invisible, so a hidden control cannot be clicked.
  Widget _fadeWithChrome(Widget child) {
    return ExcludeFocus(
      // A faded-out button is still a focusable button: without this the
      // remote walks a control bar nobody can see, and the player never gets
      // its own focus — and therefore its arrow keys — back.
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: child,
        ),
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
        macOSWindowControlsTopInset + m.topInset,
        m.gutter,
        _topBarTail,
      ),
      decoration: const BoxDecoration(gradient: EmbyChromeTheme.topScrim),
      child: _dodgeCutouts(
        Row(
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
          // Left out entirely on a television: the set and its remote own the
          // volume, so the slider would do a job that is already done — and,
          // being the one focusable widget up here, it would collect the
          // remote's focus and hold it. Same conclusion on a phone, for the
          // same reason with different hardware — see [showVolume].
          if (!isTv && showVolume)
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
          height: m.logoHeight,
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
          fontSize: m.brandTextSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // --- Bottom -------------------------------------------------------------

  Widget _buildBottom(EmbyChromeMetrics m) {
    // The scrim is painted *behind* the rows rather than around them, and it
    // does not take touches.
    //
    // A `Container` with a decoration is a `DecoratedBox`, and that asks the
    // decoration whether a point is inside it — which, for a rectangle, is
    // always yes. So the gradient was swallowing every touch that landed
    // anywhere in this bar's box, including the empty strip along its top;
    // and this bar is two thirds of a phone's height held sideways. That is
    // what stopped the brightness bar answering in its lower half: not the
    // buttons, the scrim behind them.
    return Stack(
      children: [
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: EmbyChromeTheme.bottomScrim),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            m.gutter,
            _bottomBarLead,
            m.gutter,
            m.bottomInset,
          ),
          child: _buildBottomRows(m),
        ),
      ],
    );
  }

  Widget _buildBottomRows(EmbyChromeMetrics m) {
    // Every row dodges the camera on its own: on a phone held sideways this
    // bar is half the height of the screen, so a bubble on the edge lands on
    // one of these rows and not on the others.
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.isCompact) ...[
            _dodgeCutouts(_buildTitleBlock(m)),
            const SizedBox(height: 10),
          ] else
            _dodgeCutouts(
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: _buildTitleBlock(m)),
                  const SizedBox(width: 24),
                  _buildUtilities(m),
                ],
              ),
            ),
          const SizedBox(height: 6),
          _dodgeCutouts(
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
          ),
          _dodgeCutouts(_buildTimes(m)),
          const SizedBox(height: 4),
          // Compact gives the utilities their own centred row: side by side
          // with the transport they need ~414px, which does not fit a phone.
          if (m.isCompact) ...[
            _dodgeCutouts(Center(child: _buildTransport(m))),
            const SizedBox(height: 2),
            _dodgeCutouts(Center(child: _buildUtilities(m))),
          ] else
            _dodgeCutouts(_buildTransport(m)),
        ],
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
            key: const ValueKey('emby-episodes'),
            icon: Icons.playlist_play_rounded,
            tooltip: 'Épisodes suivants',
            metrics: m,
            isTv: isTv,
            onPressed: onOpenEpisodes!,
          ),
          SizedBox(width: m.clusterGap),
        ],
        _EmbyIconButton(
          key: const ValueKey('emby-subtitles'),
          buttonKey: subtitlesButtonKey,
          icon: Icons.closed_caption_rounded,
          tooltip: 'Sous-titres',
          metrics: m,
          isTv: isTv,
          onPressed: onToggleSubtitles,
        ),
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          key: const ValueKey('emby-audio'),
          icon: Icons.graphic_eq_rounded,
          tooltip: 'Pistes audio',
          metrics: m,
          isTv: isTv,
          onPressed: onOpenAudio,
        ),
        // Not on a television: the rate lives in the settings menu, and one
        // button fewer is one press fewer to reach the settings.
        if (!isTv) ...[
          SizedBox(width: m.clusterGap),
          _EmbyIconButton(
            key: const ValueKey('emby-speed'),
            icon: Icons.speed_rounded,
            // The current rate is the whole point of the control, so it goes
            // in the tooltip rather than making the user open a menu to read it.
            tooltip: 'Vitesse ×${_formatRate(playbackRate)}',
            metrics: m,
            onPressed: onCycleSpeed,
          ),
        ],
        SizedBox(width: m.clusterGap),
        _EmbyIconButton(
          key: const ValueKey('emby-settings'),
          buttonKey: settingsButtonKey,
          icon: Icons.settings_rounded,
          tooltip: 'Réglages',
          metrics: m,
          isTv: isTv,
          onPressed: onOpenSettings,
        ),
        // A television has no window to fill: the button would do nothing.
        if (!isTv) ...[
          SizedBox(width: m.clusterGap),
          _EmbyIconButton(
            key: const ValueKey('emby-fullscreen'),
            icon: Icons.fullscreen_rounded,
            tooltip: 'Plein écran',
            metrics: m,
            onPressed: onToggleFullscreen,
          ),
        ],
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
    // Keyed, because the episode buttons come and go — the neighbours load
    // after playback starts — and without keys every button after them would
    // inherit the state, and the focus, of the one that used to sit there.
    //
    // On a television the seek buttons are drawn larger: they sit alone in the
    // middle of the picture, next to a play button that is larger still.
    final sideSize = isTv ? m.iconSize + 8 : null;
    final gap = SizedBox(width: m.clusterGap + (isTv ? 16 : 4));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Same rule as the next button: only when there is somewhere to go.
        if (onSkipPrevious != null) ...[
          _EmbyIconButton(
            key: const ValueKey('emby-previous'),
            icon: Icons.skip_previous_rounded,
            tooltip: 'Épisode précédent',
            metrics: m,
            isTv: isTv,
            onPressed: onSkipPrevious!,
          ),
          gap,
        ],
        _EmbyIconButton(
          key: const ValueKey('emby-rewind'),
          icon: Icons.replay_10_rounded,
          tooltip: 'Reculer de 10 s',
          metrics: m,
          size: sideSize,
          isTv: isTv,
          onPressed: onRewind,
        ),
        gap,
        _EmbyIconButton(
          key: const ValueKey('emby-play-pause'),
          icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: isPlaying ? 'Pause' : 'Lecture',
          metrics: m,
          size: m.playIconSize,
          focusNode: playPauseFocusNode,
          isTv: isTv,
          prominent: isTv,
          onPressed: onPlayPause,
        ),
        gap,
        _EmbyIconButton(
          key: const ValueKey('emby-forward'),
          icon: Icons.forward_10_rounded,
          tooltip: 'Avancer de 10 s',
          metrics: m,
          size: sideSize,
          isTv: isTv,
          onPressed: onForward,
        ),
        // Series only: on a movie, or at the end of a season, there is nothing
        // to go to and the button would sit there doing nothing.
        if (onSkipNext != null) ...[
          gap,
          _EmbyIconButton(
            key: const ValueKey('emby-next'),
            icon: Icons.skip_next_rounded,
            tooltip: 'Épisode suivant',
            metrics: m,
            isTv: isTv,
            onPressed: onSkipNext!,
          ),
        ],
      ],
    );
  }
}

/// Flat Emby icon button, reachable three ways: pointer, finger, and D-pad.
///
/// The remote is the reason this is wrapped in a [TvFocusable] rather than
/// left as a bare [GestureDetector]. Nothing in this chrome used to request
/// focus, so on a television the only focusable widget in it was the volume
/// slider — the remote landed there and had nowhere else to go.
class _EmbyIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final EmbyChromeMetrics metrics;

  /// Overrides [EmbyChromeMetrics.iconSize] (play/pause is larger).
  final double? size;

  /// Anchor for popups that open above this button.
  final GlobalKey? buttonKey;

  /// Supplied for the one button the remote is sent to on entry.
  final FocusNode? focusNode;

  /// Television treatment: the button under the remote is filled with the
  /// accent, which reads from across a room where a brighter icon does not.
  final bool isTv;

  /// Television only: a translucent disc even at rest, for the one button the
  /// transport is built around.
  final bool prominent;

  const _EmbyIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.metrics,
    this.size,
    this.buttonKey,
    this.focusNode,
    this.isTv = false,
    this.prominent = false,
  });

  @override
  State<_EmbyIconButton> createState() => _EmbyIconButtonState();
}

class _EmbyIconButtonState extends State<_EmbyIconButton> {
  bool _hovered = false;

  /// Owned when the chrome does not hand one in. The highlight is read from
  /// the node itself rather than from a flag kept in step with focus
  /// callbacks: a callback reports a *change*, and a node that arrives already
  /// focused, or moves between buttons, never produces one — which is how a
  /// button could hold the remote without lighting up.
  FocusNode? _ownedNode;

  FocusNode get _node =>
      widget.focusNode ?? (_ownedNode ??= FocusNode(debugLabel: 'emby-button'));

  @override
  void dispose() {
    _ownedNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final iconSize = widget.size ?? m.iconSize;
    // The box grows with an oversized icon so play/pause is not clipped.
    final box = iconSize > m.iconSize ? iconSize + 18 : m.hitSize;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: TvFocusable(
        focusNode: _node,
        onSelect: widget.onPressed,
        // A circle, so the ring hugs a round icon instead of boxing it.
        borderRadius: BorderRadius.circular(box / 2),
        // The television fill replaces the ring.
        showRing: !widget.isTv,
        // Slightly more than the app's cards get: an icon is a much smaller
        // thing to spot from a sofa, and the box has enough padding around it
        // that growing it never reaches its neighbour.
        focusScale: widget.isTv ? 1.15 : 1.12,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: widget.buttonKey,
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: ListenableBuilder(
              listenable: _node,
              builder: (context, _) {
                final focused = _node.hasFocus;
                final active = _hovered || focused;
                final filled = widget.isTv && focused;
                final Color? disc = filled
                    ? AppColors.accent
                    : widget.prominent
                        ? Colors.white.withValues(alpha: 0.16)
                        : null;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: box,
                  height: box,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: disc ?? Colors.transparent,
                    boxShadow: filled
                        ? [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.45),
                              blurRadius: 18,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    widget.icon,
                    size: iconSize,
                    color: active
                        ? EmbyChromeTheme.iconActive
                        : EmbyChromeTheme.icon,
                  ),
                );
              },
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
              data: const SliderThemeData(
                trackHeight: 3,
                activeTrackColor: EmbyChromeTheme.progressPlayed,
                inactiveTrackColor: EmbyChromeTheme.progressTrack,
                thumbColor: EmbyChromeTheme.progressPlayed,
                overlayColor: Colors.white24,
                thumbShape:
                    RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    RoundSliderOverlayShape(overlayRadius: 14),
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
    return TvFocusable(
      onSelect: onPressed,
      borderRadius: BorderRadius.circular(6),
      focusScale: 1.06,
      child: Material(
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
                fontSize: metrics.skipIntroTextSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays the chrome out as three bands: the top bar, the bottom cluster, and
/// whatever is left between them.
///
/// The middle band is the brightness bar's, and it is the whole point of doing
/// this by hand. The two bars are laid out first and *measured*; the bar is
/// then given the space that actually remains, so it can neither be drawn over
/// the buttons nor — worse, because it is invisible — catch fingers where they
/// belong to the buttons. A [Stack] could only have guessed at those heights.
class _EmbyChromeLayout extends MultiChildLayoutDelegate {
  _EmbyChromeLayout({required this.topLead, required this.bottomLead});

  /// How far the band may reach back into each bar — their empty scrim
  /// margins, which draw nothing and catch nothing.
  final double topLead;
  final double bottomLead;

  static const String top = 'top';
  static const String bottom = 'bottom';
  static const String brightness = 'brightness';

  @override
  void performLayout(Size size) {
    // Full width, and **unbounded** height: the bars are asked how tall they
    // want to be, not told how tall they may be. A bounded height is not the
    // same question — several widgets in these bars, an [Align] around the
    // title among them, answer "as tall as you'll let me" and would take the
    // whole screen. It is the constraint a [Positioned] pinned to one edge
    // gives, which is what these bars were written against.
    final natural = BoxConstraints(
      minWidth: size.width,
      maxWidth: size.width,
    );

    var topHeight = 0.0;
    if (hasChild(top)) {
      topHeight = layoutChild(top, natural).height;
      positionChild(top, Offset.zero);
    }

    var bottomHeight = 0.0;
    if (hasChild(bottom)) {
      bottomHeight = layoutChild(bottom, natural).height;
      positionChild(bottom, Offset(0, size.height - bottomHeight));
    }

    if (hasChild(brightness)) {
      // What is left between the two bars, plus the empty margin each of them
      // offers back. Never less than nothing: on a short window the bars can
      // take the whole height, and the control answers a band too small to use
      // by drawing nothing at all.
      final bandTop = (topHeight - topLead).clamp(0.0, size.height);
      final bandBottom =
          (size.height - bottomHeight + bottomLead).clamp(0.0, size.height);
      final band = (bandBottom - bandTop).clamp(0.0, size.height);
      layoutChild(
        brightness,
        BoxConstraints(
          minWidth: size.width,
          maxWidth: size.width,
          maxHeight: band,
        ),
      );
      positionChild(brightness, Offset(0, bandTop));
    }
  }

  @override
  bool shouldRelayout(_EmbyChromeLayout oldDelegate) =>
      oldDelegate.topLead != topLead || oldDelegate.bottomLead != bottomLead;
}
