import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../theme/app_colors.dart';
import '../../../../utils/format.dart';
import 'emby_chrome_theme.dart';

/// The Emby scrubber: thin white bar that thickens on hover, a handle that
/// only appears once pointed at, chapter ticks, and a time bubble following
/// the cursor.
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
                  if (_pointerFraction != null && widget.duration > Duration.zero)
                    _buildTimeBubble(width, rowHeight),
                ],
              ),
            ),
          ),
        );

        if (!widget.focusable) return bar;

        return Focus(
          onKeyEvent: _handleKey,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              bar,
              // The bar is four pixels tall; the ring the rest of the chrome
              // draws around a button would be a line on a line. It gets a
              // frame around its whole hit row instead, which is what reads
              // from a sofa.
              if (_focused)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.accent, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

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
              color: EmbyChromeTheme.progressPlayed,
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
        decoration: const BoxDecoration(
          color: EmbyChromeTheme.progressPlayed,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _buildTimeBubble(double width, double rowHeight) {
    final fraction = _pointerFraction!;
    final seconds = (widget.duration.inSeconds * fraction).round();
    final label = formatPlaybackTime(seconds);
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
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: widget.metrics.timeSize,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
