
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../theme/app_colors.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../utils/format.dart';
import '../../playback/timeline_previews.dart';
import 'emby_chrome_theme.dart';

/// The Emby scrubber: thin white bar that thickens on hover, a handle that
/// only appears once pointed at, chapter ticks, and a time bubble following
/// the cursor — which grows into a still of that moment once the player has
/// [previews].
///
/// Seeking is committed on release, not while dragging: the parent owns the
/// HLS session and a mid-drag seek to a not-yet-served segment stalls it.
class EmbyProgressBar extends StatefulWidget {
  /// Played fraction, 0.0 -> 1.0.
  final double progress;

  /// Downloaded-ahead fraction, 0.0 -> 1.0.
  final double buffered;

  final Duration duration;

  /// Chapter start positions as fractions, 0.0 -> 1.0.
  final List<double> chapterMarks;

  final EmbyChromeMetrics metrics;

  /// Fired once, on release, with the target fraction.
  final ValueChanged<double> onSeek;

  /// Raised while the user is scrubbing so the parent can hold the chrome open.
  final ValueChanged<bool>? onScrubbingChanged;

  /// Television only: the bar takes the focus, and the D-pad seeks from it.
  ///
  /// It is also what makes the rest of the chrome reachable. Directional focus
  /// traversal prefers a target in the same vertical band as the control it
  /// starts from; a full-width bar sitting between the transport row and the
  /// top bar is in the band of every one of them, so up and down always find
  /// something instead of depending on which button happens to line up with
  /// which.
  final bool focusable;

  /// What left and right do while the bar holds the focus — the same ±10 s the
  /// transport buttons carry, because a remote cannot drag a handle.
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;

  /// OK / D-pad centre while the bar holds the focus. The bar is where the
  /// remote lands, so it has to answer the most common press of all with the
  /// most common action — play/pause — rather than making the user walk down
  /// to a button for it.
  final VoidCallback? onSelect;

  /// Supplied by the player so it can put the remote here the moment the HUD
  /// comes up, instead of leaving traversal to pick a starting point.
  final FocusNode? focusNode;

  /// Stills of the timeline, shown above the pointer. Null, or not ready yet,
  /// leaves the plain time bubble.
  final TimelinePreviews? previews;

  /// Television: a remote seek is pending, so the still follows the handle —
  /// the remote has no pointer to follow.
  final bool previewAtProgress;

  const EmbyProgressBar({
    super.key,
    required this.progress,
    required this.buffered,
    required this.duration,
    required this.metrics,
    required this.onSeek,
    this.chapterMarks = const [],
    this.onScrubbingChanged,
    this.focusable = false,
    this.onStepBack,
    this.onStepForward,
    this.onSelect,
    this.focusNode,
    this.previews,
    this.previewAtProgress = false,
  });

  @override
  State<EmbyProgressBar> createState() => _EmbyProgressBarState();
}

class _EmbyProgressBarState extends State<EmbyProgressBar> {
  bool _hovered = false;
  bool _focused = false;
  double? _dragFraction;
  double? _pointerFraction;

  /// Pointed at, dragged, or standing under the remote — all three mean the
  /// bar is the thing being aimed at, and all three thicken it.
  bool get _active => _hovered || _focused || _dragFraction != null;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (kTvSelectKeys.contains(key)) {
      final select = widget.onSelect;
      if (select == null) return KeyEventResult.ignored;
      // Holding OK is one play/pause, not one per repeat.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      select();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final step = widget.onStepBack;
      if (step == null) return KeyEventResult.ignored;
      step();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final step = widget.onStepForward;
      if (step == null) return KeyEventResult.ignored;
      step();
      return KeyEventResult.handled;
    }
    // Up and down are the traversal's, so the remote can leave the bar.
    return KeyEventResult.ignored;
  }

  /// What the bar draws: the drag position while scrubbing, so the bar tracks
  /// the finger even though the seek itself only lands on release.
  double get _shownFraction =>
      (_dragFraction ?? widget.progress).clamp(0.0, 1.0);

  double _fractionFor(double dx, double width) =>
      width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0);

  void _setDrag(double? value) {
    setState(() => _dragFraction = value);
    widget.onScrubbingChanged?.call(value != null);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    // The row is taller than the bar so there is something to aim at: a 4px
    // bar is not a target, on a mouse or a finger.
    final rowHeight = m.hitSize;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        final bar = MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pointerFraction = null;
          }),
          onHover: (event) => setState(
            () => _pointerFraction = _fractionFor(event.localPosition.dx, width),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                widget.onSeek(_fractionFor(d.localPosition.dx, width)),
            onHorizontalDragStart: (d) =>
                _setDrag(_fractionFor(d.localPosition.dx, width)),
            onHorizontalDragUpdate: (d) => setState(() {
              _dragFraction = _fractionFor(d.localPosition.dx, width);
              _pointerFraction = _dragFraction;
            }),
            onHorizontalDragEnd: (_) {
              final target = _dragFraction;
              _setDrag(null);
              if (target != null) widget.onSeek(target);
            },
            onHorizontalDragCancel: () => _setDrag(null),
            child: SizedBox(
              height: rowHeight,
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  _buildBar(width),
                  if (_active) _buildHandle(width),
                  if (_previewFraction != null &&
                      widget.duration > Duration.zero)
                    _buildPointerLabel(width, rowHeight),
                ],
              ),
            ),
          ),
        );

        if (!widget.focusable) return bar;

        // No frame around a focused bar: the bar itself says it. It thickens
        // and turns to the accent, which is what the eye is already on.
        return Focus(
          focusNode: widget.focusNode,
          onKeyEvent: _handleKey,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: bar,
        );
      },
    );
  }

  /// The played part and the handle: the accent under the remote, white
  /// otherwise.
  Color get _playedColor =>
      _focused ? AppColors.accent : EmbyChromeTheme.progressPlayed;

  Widget _buildBar(double width) {
    final m = widget.metrics;
    final thickness = _active ? m.barThicknessActive : m.barThickness;
    final radius = BorderRadius.circular(thickness);

    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        height: thickness,
        width: width,
        decoration: BoxDecoration(
          color: EmbyChromeTheme.progressTrack,
          borderRadius: radius,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _fill(
              width: widget.buffered.clamp(0.0, 1.0) * width,
              color: EmbyChromeTheme.progressBuffered,
              radius: radius,
            ),
            _fill(
              width: _shownFraction * width,
              color: _playedColor,
              radius: radius,
            ),
            // Ticks sit on top of the fills, so a chapter boundary stays
            // readable in the part of the bar that has already played.
            for (final mark in widget.chapterMarks)
              if (mark > 0.001 && mark < 0.999)
                Positioned(
                  left: mark * width,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: const ColoredBox(color: EmbyChromeTheme.chapterMark),
                ),
          ],
        ),
      ),
    );
  }

  /// One coloured segment of the bar, anchored to its left edge.
  Widget _fill({
    required double width,
    required Color color,
    required BorderRadius radius,
  }) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: width.clamp(0.0, double.infinity),
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: radius),
      ),
    );
  }

  Widget _buildHandle(double width) {
    final size = widget.metrics.handleSize;
    return Positioned(
      left: (_shownFraction * width) - size / 2,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _playedColor,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  /// Where the still or bubble points: the mouse or finger, or on a
  /// television the pending seek.
  double? get _previewFraction =>
      _pointerFraction ??
      (_focused && widget.previewAtProgress ? _shownFraction : null);

  Widget _buildPointerLabel(double width, double rowHeight) {
    final previews = widget.previews;
    if (previews == null) return _buildTimeBubble(width, rowHeight);
    // Only the label rebuilds as stills arrive, not the whole bar.
    return ListenableBuilder(
      listenable: previews,
      builder: (context, _) => previews.isReady
          ? _buildPreview(width, rowHeight, previews)
          : _buildTimeBubble(width, rowHeight),
    );
  }

  Widget _buildPreview(
    double width,
    double rowHeight,
    TimelinePreviews previews,
  ) {
    final manifest = previews.manifest!;
    final fraction = _previewFraction!;
    final position = Duration(
      milliseconds: (widget.duration.inMilliseconds * fraction).round(),
    );
    final index = manifest.indexFor(position);
    // Asynchronous by contract: the fetch it may start notifies later.
    previews.request(index);
    final image = previews.imageFor(index);

    final boxWidth = widget.metrics.previewWidth.clamp(0.0, width);
    final boxHeight = boxWidth / manifest.aspectRatio;
    final left =
        (fraction * width - boxWidth / 2).clamp(0.0, width - boxWidth);
    final radius = BorderRadius.circular(8);

    return Positioned(
      left: left,
      bottom: rowHeight / 2 + 12,
      child: IgnorePointer(
        child: Container(
          width: boxWidth,
          decoration: BoxDecoration(
            color: EmbyChromeTheme.tooltipSurface,
            borderRadius: radius,
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          // Drawn over the still rather than around it, so the picture keeps
          // its full width.
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: const Color(0x40FFFFFF)),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: boxWidth,
                  height: boxHeight,
                  child: image == null
                      ? null
                      : Image(
                          image: image,
                          fit: BoxFit.cover,
                          // Holds the previous still until the next one is
                          // decoded, so a scrub never flashes to empty.
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: _timeLabel(position.inSeconds),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeLabel(int seconds) {
    return Text(
      formatPlaybackTime(seconds),
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.metrics.timeSize,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _buildTimeBubble(double width, double rowHeight) {
    final fraction = _previewFraction!;
    final seconds = (widget.duration.inSeconds * fraction).round();
    // Clamped so the bubble never hangs off either end of the bar.
    const bubbleWidth = 68.0;
    final left =
        (fraction * width - bubbleWidth / 2).clamp(0.0, width - bubbleWidth);

    return Positioned(
      left: left,
      bottom: rowHeight / 2 + 12,
      child: IgnorePointer(
        child: Container(
          width: bubbleWidth,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: EmbyChromeTheme.tooltipSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: _timeLabel(seconds),
        ),
      ),
    );
  }
}
