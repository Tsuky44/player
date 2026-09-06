import 'package:flutter/material.dart';

import 'emby_chrome_theme.dart';

/// The vertical brightness bar down the left edge of the player, the control
/// every phone video app puts there.
///
/// The left edge is not interchangeable with the right one: the right is where
/// this chrome's utility buttons live, and a bar in their column covers them.
///
/// It is a bar rather than a [Slider] on purpose. A Slider's thumb is a target
/// to find before the gesture can start; this one takes the touch wherever it
/// lands on the column and follows the finger from there, which is the only
/// interaction that works when the hand holding the phone is also the hand
/// doing the adjusting. The whole column is the target, 44 px of it, with the
/// drawn track kept thin inside it.
class EmbyBrightnessSlider extends StatefulWidget {
  /// 0.0 -> 1.0.
  final double value;

  final ValueChanged<double> onChanged;

  /// Signals the start and end of a drag, so the chrome can stay up for the
  /// whole of it instead of fading out from under the finger.
  final ValueChanged<bool>? onDraggingChanged;

  final EmbyChromeMetrics metrics;

  const EmbyBrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.metrics,
    this.onDraggingChanged,
  });

  @override
  State<EmbyBrightnessSlider> createState() => _EmbyBrightnessSliderState();
}

class _EmbyBrightnessSliderState extends State<EmbyBrightnessSlider> {
  /// Width of the drawn track. The touch target around it is [_hitWidth],
  /// which stays at the 44 px a finger needs however thin the track is drawn.
  static const double _trackWidth = 5;
  static const double _hitWidth = 44;

  bool _dragging = false;

  /// Height of the track as laid out, so a drag can be converted to a value.
  double _trackHeight = 1;

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
    widget.onDraggingChanged?.call(value);
  }

  /// Turns a local y inside the track into a brightness.
  ///
  /// Inverted: up is brighter, which is the direction the bar itself grows.
  void _emit(double localY) {
    if (_trackHeight <= 0) return;
    final v = 1 - (localY / _trackHeight);
    widget.onChanged(v.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final value = widget.value.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Under a quarter of the screen's height, bounded so it neither
        // disappears on a small phone nor runs into the chrome on a tablet.
        // Short on purpose: the bar is read at a glance and driven by a drag
        // that can start anywhere on it, so length buys nothing — it only
        // takes room from the film, which is what the eye is actually on.
        final trackHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * 0.22).clamp(80.0, 140.0)
            : 110.0;
        _trackHeight = trackHeight;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Taking the pan on the *vertical* axis only leaves the
              // horizontal one to whatever is behind — nothing here, but it
              // also keeps this out of the arena for the player's pinch.
              onVerticalDragStart: (d) {
                _setDragging(true);
                _emit(d.localPosition.dy);
              },
              onVerticalDragUpdate: (d) => _emit(d.localPosition.dy),
              onVerticalDragEnd: (_) => _setDragging(false),
              onVerticalDragCancel: () => _setDragging(false),
              onTapDown: (d) => _emit(d.localPosition.dy),
              child: SizedBox(
                width: _hitWidth,
                height: trackHeight,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    width: _dragging ? _trackWidth + 2 : _trackWidth,
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: EmbyChromeTheme.progressTrack,
                      borderRadius: BorderRadius.circular(_trackWidth),
                      // The bar sits over the picture, not over a scrim, so
                      // without this it vanishes on a bright frame.
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    // The fill grows from the bottom, matching the direction
                    // of the gesture that produces it.
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: value,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: EmbyChromeTheme.progressPlayed,
                            borderRadius: BorderRadius.circular(_trackWidth),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Says what the bar is for. Below it rather than above, so it stays
            // clear of the finger for the whole of an upward drag.
            Icon(
              value < 0.35
                  ? Icons.brightness_low_rounded
                  : value < 0.75
                      ? Icons.brightness_medium_rounded
                      : Icons.brightness_high_rounded,
              size: m.iconSize,
              color: EmbyChromeTheme.icon,
              shadows: const [
                Shadow(color: Color(0x99000000), blurRadius: 8),
              ],
            ),
          ],
        );
      },
    );
  }
}
